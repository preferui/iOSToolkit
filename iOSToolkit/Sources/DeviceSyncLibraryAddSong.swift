import Foundation
import SQLite3

/// Thêm MỘT bài hát từ tệp nhạc local của người dùng vào thư viện Apple Music của thiết bị.
///
/// Phạm vi CÓ CHỦ Ý thu hẹp so với ByeTunes gốc để giảm rủi ro ở bước đầu tiên của tính năng ghi:
/// - CHỈ hỗ trợ "thêm vào thư viện đã có sẵn" (máy đã từng mở app Nhạc ít nhất 1 lần). KHÔNG tự
///   tạo database thư viện từ đầu nếu chưa có — báo lỗi rõ ràng thay vì làm điều rủi ro hơn.
/// - KHÔNG kèm ảnh bìa / lời bài hát / chapter / video-trait ở bản đầu tiên — chỉ các bảng cốt lõi
///   để bài hát phát được và hiển thị đúng tên/ca sĩ/album trong thư viện. Có thể bổ sung sau.
/// - Nếu đã có bài trùng (cùng tiêu đề + ca sĩ + album), BỎ QUA thay vì ghi đè — an toàn hơn ghi đè
///   nhầm lên bài đã có sẵn số liệu nghe/play count.
enum AddSongError: LocalizedError {
    case afcConnectFailed
    case schemaUnexpected(String)
    case alreadyExists(String)
    case uploadAudioFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .afcConnectFailed: return "Không kết nối được AFC."
        case .schemaUnexpected(let detail): return "Database thư viện có cấu trúc không như mong đợi: \(detail)"
        case .alreadyExists(let title): return "Bài hát \"\(title)\" (trùng tên + ca sĩ + album) đã có trong thư viện — bỏ qua, không thêm lại."
        case .uploadAudioFailed: return "Tải tệp âm thanh lên thiết bị thất bại."
        case .cancelled: return "Đã huỷ."
        }
    }
}

extension DeviceSyncManager {
    /// Thêm 1 bài hát. `onProgress` được gọi trên main thread với các mốc tiến trình tiếng Việt.
    func addSong(from metadata: LocalSongMetadata, onProgress: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func reportProgress(_ text: String) { DispatchQueue.main.async { onProgress(text) } }
            func finish(_ result: Result<Void, Error>) { DispatchQueue.main.async { completion(result) } }

            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            guard connectErr == IdeviceSuccess, let afc else {
                finish(.failure(AddSongError.afcConnectFailed)); return
            }
            defer { afc_client_free(afc) }

            reportProgress("Đang tải database thư viện hiện tại…")
            let staged: StagedMediaLibrary
            do {
                staged = try self.stageMediaLibraryForWriting(afc)
            } catch {
                finish(.failure(error)); return
            }
            defer { try? FileManager.default.removeItem(at: staged.tempDir) }

            var db: OpaquePointer?
            guard sqlite3_open(staged.dbURL.path, &db) == SQLITE_OK, let db else {
                finish(.failure(AddSongError.schemaUnexpected("không mở lại được database cục bộ")))
                return
            }
            // QUAN TRỌNG: đóng connection này NGAY sau khi ghi xong, TRƯỚC khi gọi
            // commitMediaLibrary (hàm đó tự mở 1 connection riêng tới CÙNG tệp để checkpoint WAL
            // + đổi journal_mode trước khi tải lên thiết bị). Nếu còn connection khác đang mở tới
            // cùng tệp, SQLite không đổi journal_mode được (yêu cầu truy cập độc quyền) và việc
            // checkpoint có thể không gộp hết dữ liệu — tệp tải lên thiết bị dễ thiếu đúng phần bài
            // hát vừa ghi. KHÔNG dùng `defer` ở đây để tránh giữ connection mở xuyên suốt hàm.

            do {
                reportProgress("Đang kiểm tra trùng lặp…")
                try Self.ensureBaseLocation(db)

                let signature = "\(metadata.title)|\(metadata.artist)|\(metadata.album)"
                if Self.existingSongSignatures(db).contains(signature) {
                    sqlite3_close(db)
                    finish(.failure(AddSongError.alreadyExists(metadata.title)))
                    return
                }

                reportProgress("Đang ghi thông tin bài hát vào database…")
                try Self.insertSong(db, metadata: metadata)
            } catch {
                sqlite3_close(db)
                finish(.failure(error)); return
            }

            sqlite3_close(db)

            reportProgress("Đang tải tệp âm thanh lên thiết bị…")
            let musicDir = "/iTunes_Control/Music/F00"
            self.afcEnsureDirectory(afc, path: "/iTunes_Control")
            self.afcEnsureDirectory(afc, path: "/iTunes_Control/Music")
            self.afcEnsureDirectory(afc, path: musicDir)
            let remotePath = "\(musicDir)/\(metadata.remoteFilename)"
            guard self.afcUploadFile(afc, localURL: metadata.localURL, remotePath: remotePath) else {
                finish(.failure(AddSongError.uploadAudioFailed)); return
            }

            reportProgress("Đang kích hoạt database mới trên thiết bị…")
            do {
                try self.commitMediaLibrary(afc, localDbURL: staged.dbURL)
            } catch {
                // Database upload thất bại — dọn luôn tệp âm thanh vừa tải lên để không để lại rác
                // không có database trỏ tới (tránh gây lẫn lộn ở lần đồng bộ sau).
                _ = self.afcRemoveFile(afc, remotePath: remotePath)
                finish(.failure(error)); return
            }

            self.sendSyncFinishedNotification()
            self.postLibraryRefreshNotifications()
            finish(.success(()))
        }
    }

    private static func ensureBaseLocation(_ db: OpaquePointer) throws {
        try execSQL(db, "INSERT OR IGNORE INTO base_location (base_location_id, path) VALUES (3840, 'iTunes_Control/Music/F00')")
    }

    private static func existingSongSignatures(_ db: OpaquePointer) -> Set<String> {
        var signatures = Set<String>()
        var stmt: OpaquePointer?
        let query = """
            SELECT item_extra.title, item_artist.item_artist, album.album
            FROM item
            LEFT JOIN item_extra ON item.item_pid = item_extra.item_pid
            LEFT JOIN item_artist ON item.item_artist_pid = item_artist.item_artist_pid
            LEFT JOIN album ON item.album_pid = album.album_pid
            WHERE item.media_type = 8
        """
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let artist = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let album = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                if !title.isEmpty { signatures.insert("\(title)|\(artist)|\(album)") }
            }
        }
        sqlite3_finalize(stmt)
        return signatures
    }

    /// Sinh persistent id kiểu Apple Music (Int64 ngẫu nhiên lớn) — cùng thuật toán ByeTunes dùng.
    private static func generatePersistentId() -> Int64 {
        Int64.random(in: 1_000_000_000_000_000_000...Int64.max)
    }

    private static func groupingKeyHex(_ text: String) -> String {
        var result = [UInt8]()
        for char in text.uppercased() {
            if char >= "A" && char <= "Z" {
                result.append(UInt8(char.asciiValue! - Character("A").asciiValue! + 1))
            } else if char == " " {
                result.append(0x04)
            } else if char == "/" {
                result.append(0x0A)
            }
        }
        return result.map { String(format: "%02x", $0) }.joined()
    }

    /// name -> (order, section) trong bảng sort_map dùng chung cho sắp xếp A-Z toàn thư viện.
    private static func insertSortMap(_ db: OpaquePointer, name: String) -> (order: Int64, section: Int) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name_order, name_section FROM sort_map WHERE name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                let order = sqlite3_column_int64(stmt, 0)
                let section = Int(sqlite3_column_int(stmt, 1))
                sqlite3_finalize(stmt)
                return (order, section)
            }
        }
        sqlite3_finalize(stmt)

        var maxOrder: Int64 = 0
        var maxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(name_order) FROM sort_map", -1, &maxStmt, nil) == SQLITE_OK {
            if sqlite3_step(maxStmt) == SQLITE_ROW { maxOrder = sqlite3_column_int64(maxStmt, 0) }
        }
        sqlite3_finalize(maxStmt)
        let nameOrder = maxOrder + 1

        var nameSection = 26
        let normalized = name.folding(options: .diacriticInsensitive, locale: .current)
        if let firstChar = normalized.uppercased().first, let ascii = firstChar.asciiValue {
            let v = Int(ascii)
            if v >= 65 && v <= 90 { nameSection = v - 65 }
        }

        var insertStmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO sort_map (name, name_order, name_section, sort_key) VALUES (?, ?, ?, X'\(groupingKeyHex(name))')"
        if sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(insertStmt, 2, nameOrder)
            sqlite3_bind_int(insertStmt, 3, Int32(nameSection))
            sqlite3_step(insertStmt)
        }
        sqlite3_finalize(insertStmt)
        return (nameOrder, nameSection)
    }

    private static func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
        var exists = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(stmt, 1), String(cString: namePtr) == column {
                    exists = true; break
                }
            }
        }
        sqlite3_finalize(stmt)
        return exists
    }

    /// COUNT(*) FROM item + 1 — cùng cách bản gốc ByeTunes sinh track_number mặc định khi tệp
    /// nhạc không tự có số track riêng.
    private static func nextTrackNumber(_ db: OpaquePointer) -> Int64 {
        var count: Int64 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM item", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { count = sqlite3_column_int64(stmt, 0) }
        }
        sqlite3_finalize(stmt)
        return count + 1
    }

    private static func lookupOrCreatePid(_ db: OpaquePointer, table: String, nameColumn: String, pidColumn: String, name: String) throws -> (pid: Int64, isNew: Bool) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT \(pidColumn) FROM \(table) WHERE \(nameColumn) = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                let pid = sqlite3_column_int64(stmt, 0)
                sqlite3_finalize(stmt)
                return (pid, false)
            }
        }
        sqlite3_finalize(stmt)
        return (generatePersistentId(), true)
    }

    private static func insertSong(_ db: OpaquePointer, metadata m: LocalSongMetadata) throws {
        let now = Int(Date().timeIntervalSince1970)

        let (artistPid, artistIsNew) = try lookupOrCreatePid(db, table: "item_artist", nameColumn: "item_artist", pidColumn: "item_artist_pid", name: m.artist)
        let effectiveAlbumArtist = m.albumArtist ?? m.artist
        let (albumArtistPid, albumArtistIsNew) = try lookupOrCreatePid(db, table: "album_artist", nameColumn: "album_artist", pidColumn: "album_artist_pid", name: effectiveAlbumArtist)
        let (albumPid, albumIsNew) = try lookupOrCreatePid(db, table: "album", nameColumn: "album", pidColumn: "album_pid", name: m.album)
        let (genreId, genreIsNew) = try lookupOrCreatePid(db, table: "genre", nameColumn: "genre", pidColumn: "genre_id", name: m.genre)

        let itemPid = generatePersistentId()

        // track_number: bản gốc ByeTunes dùng số đếm TĂNG DẦN (COUNT(*) FROM item + 1) khi tệp
        // nhạc không có track number riêng — KHÔNG hardcode 1 cho mọi bài. 2 bài cùng album có
        // disc_number+track_number trùng nhau có thể khiến app Nhạc hiển thị sai (từng gặp: tên
        // bài trống khi 2 bài cùng album đều "track 1").
        let trackNumber = Self.nextTrackNumber(db)

        let titleSort = insertSortMap(db, name: m.title)
        let artistSort = insertSortMap(db, name: m.artist)
        let albumSort = insertSortMap(db, name: m.album)
        let genreSort = insertSortMap(db, name: m.genre)

        let ext = m.localURL.pathExtension
        let audioFmt = MediaLibraryAudioFormat.forExtension(ext)

        try execSQL(db, """
            INSERT INTO item (
                item_pid, media_type, title_order, title_order_section,
                item_artist_pid, item_artist_order, item_artist_order_section,
                series_name_order, series_name_order_section,
                album_pid, album_order, album_order_section,
                album_artist_pid, album_artist_order, album_artist_order_section,
                composer_pid, composer_order, composer_order_section,
                genre_id, genre_order, genre_order_section,
                disc_number, track_number, episode_sort_id,
                base_location_id, remote_location_id,
                exclude_from_shuffle, keep_local, keep_local_status, keep_local_status_reason, keep_local_constraints,
                in_my_library, is_compilation, date_added, show_composer, is_music_show, date_downloaded, download_source_container_pid
            ) VALUES (
                \(itemPid), 8, \(titleSort.order), \(titleSort.section),
                \(artistPid), \(artistSort.order), \(artistSort.section),
                0, 26,
                \(albumPid), \(albumSort.order), \(albumSort.section),
                \(albumArtistPid), \(artistSort.order), \(artistSort.section),
                0, 0, 26,
                \(genreId), \(genreSort.order), \(genreSort.section),
                1, \(trackNumber), 1,
                3840, 0,
                0, 1, 2, 0, 0,
                1, 0, \(now), 0, 0, \(now), 0
            )
        """)

        let escapedTitle = m.title.sqlEscaped
        let escapedFilename = m.remoteFilename.sqlEscaped
        try execSQL(db, """
            INSERT INTO item_extra (
                item_pid, title, sort_title, disc_count, track_count, total_time_ms, year,
                location, file_size, integrity, is_audible_audio_book, date_modified,
                media_kind, content_rating, content_rating_level, is_user_disabled, bpm, genius_id,
                location_kind_id, copyright
            ) VALUES (
                \(itemPid), '\(escapedTitle)', '\(escapedTitle)', 1, 1, \(m.durationMs), \(m.year),
                '\(escapedFilename)', \(m.fileSize), X'', 0, \(now),
                1, 0, 0, 0, 0, 0,
                42, ''
            )
        """)

        try execSQL(db, """
            INSERT INTO item_playback (
                item_pid, audio_format, bit_rate, codec_type, codec_subtype, data_kind,
                duration, has_video, relative_volume, sample_rate
            ) VALUES (
                \(itemPid), \(audioFmt), 320, 0, 0, 0,
                0, 0, 0, 44100.0
            )
        """)

        try execSQL(db, "INSERT OR REPLACE INTO item_stats (item_pid, date_accessed) VALUES (\(itemPid), \(now))")
        // item_video/chapter: bản gốc ghi cho MỌI bài hát (kể cả nhạc thường, không chỉ video) —
        // một số view trong app Nhạc join tới các bảng này, nên ghi hàng rỗng để không thiếu.
        try execSQL(db, "INSERT OR REPLACE INTO item_video (item_pid, hls_asset_traits) VALUES (\(itemPid), 0)")
        try execSQL(db, "INSERT OR REPLACE INTO chapter (item_pid) VALUES (\(itemPid))")
        try execSQL(db, """
            INSERT OR REPLACE INTO item_search (item_pid, search_title, search_album, search_artist, search_composer, search_album_artist)
            VALUES (\(itemPid), \(titleSort.order), \(albumSort.order), \(artistSort.order), 0, \(artistSort.order))
        """)

        // item_store: không có dữ liệu catalog Apple thật (bài hát local của người dùng) — ghi hàng
        // tối thiểu với placeholder an toàn, giống nhánh "không khớp catalog" của ByeTunes, để các
        // view khác trong app Nhạc không gặp hàng thiếu khi join tới item_store.
        let syncId = generatePersistentId()
        let placeholderId = 9_000_000_000 + abs(itemPid % 900_000_000)
        try execSQL(db, """
            INSERT OR REPLACE INTO item_store (
                item_pid, sync_id, sync_in_my_library, is_subscription,
                store_saga_id, match_redownload_params, cloud_status,
                store_xid, store_item_id, storefront_id,
                store_composer_id, store_genre_id, store_playlist_id,
                date_released, subscription_store_item_id,
                is_mastered_for_itunes, store_flavor,
                cloud_asset_available, cloud_in_my_library,
                playback_endpoint_type, cloud_playback_endpoint_type
            ) VALUES (
                \(itemPid), \(syncId), 1, 0,
                \(placeholderId), '', 8,
                '', \(placeholderId), 143441,
                0, 0, \(placeholderId),
                0, \(placeholderId),
                0, '',
                0, 1,
                0, 0
            )
        """)

        if artistIsNew {
            let groupingHex = groupingKeyHex(m.artist)
            let escaped = m.artist.sqlEscaped
            try execSQL(db, """
                INSERT INTO item_artist (item_artist_pid, item_artist, sort_item_artist, series_name, grouping_key, sync_id, keep_local, representative_item_pid, store_id)
                VALUES (\(artistPid), '\(escaped)', '\(escaped)', '', X'\(groupingHex)', \(generatePersistentId()), 1, \(itemPid), 0)
            """)
        }

        if albumArtistIsNew {
            let groupingHex = groupingKeyHex(effectiveAlbumArtist)
            let escaped = effectiveAlbumArtist.sqlEscaped
            let sort = insertSortMap(db, name: effectiveAlbumArtist)
            let hasSortOrder = columnExists(db, table: "album_artist", column: "sort_order")
            let hasNameOrder = columnExists(db, table: "album_artist", column: "name_order")
            if hasSortOrder && hasNameOrder {
                try execSQL(db, """
                    INSERT INTO album_artist (album_artist_pid, album_artist, sort_album_artist, grouping_key, sync_id, keep_local, representative_item_pid, sort_order, sort_order_section, name_order, store_id)
                    VALUES (\(albumArtistPid), '\(escaped)', '\(escaped)', X'\(groupingHex)', \(generatePersistentId()), 1, \(itemPid), \(sort.order), \(sort.section), \(sort.order), 0)
                """)
            } else if hasSortOrder {
                try execSQL(db, """
                    INSERT INTO album_artist (album_artist_pid, album_artist, sort_album_artist, grouping_key, sync_id, keep_local, representative_item_pid, sort_order, sort_order_section, store_id)
                    VALUES (\(albumArtistPid), '\(escaped)', '\(escaped)', X'\(groupingHex)', \(generatePersistentId()), 1, \(itemPid), \(sort.order), \(sort.section), 0)
                """)
            } else {
                try execSQL(db, """
                    INSERT INTO album_artist (album_artist_pid, album_artist, sort_album_artist, grouping_key, sync_id, keep_local, representative_item_pid, store_id)
                    VALUES (\(albumArtistPid), '\(escaped)', '\(escaped)', X'\(groupingHex)', \(generatePersistentId()), 1, \(itemPid), 0)
                """)
            }
        }

        if albumIsNew {
            let groupingHex = groupingKeyHex(m.album)
            let escaped = m.album.sqlEscaped
            let hasStoreId = columnExists(db, table: "album", column: "store_id")
            if hasStoreId {
                try execSQL(db, """
                    INSERT INTO album (album_pid, album, sort_album, album_artist_pid, grouping_key, album_year, keep_local, sync_id, representative_item_pid, store_id)
                    VALUES (\(albumPid), '\(escaped)', '\(escaped)', \(albumArtistPid), X'\(groupingHex)', \(m.year), 1, \(generatePersistentId()), \(itemPid), 0)
                """)
            } else {
                try execSQL(db, """
                    INSERT INTO album (album_pid, album, sort_album, album_artist_pid, grouping_key, album_year, keep_local, sync_id, representative_item_pid)
                    VALUES (\(albumPid), '\(escaped)', '\(escaped)', \(albumArtistPid), X'\(groupingHex)', \(m.year), 1, \(generatePersistentId()), \(itemPid))
                """)
            }
        }

        if genreIsNew {
            let groupingHex = groupingKeyHex(m.genre)
            let escaped = m.genre.sqlEscaped
            try execSQL(db, """
                INSERT INTO genre (genre_id, genre, grouping_key, representative_item_pid)
                VALUES (\(genreId), '\(escaped)', X'\(groupingHex)', \(itemPid))
            """)
        }

        // Bản gốc luôn chạy 3 câu "vá" này sau khi ghi xong — phòng trường hợp có hàng cũ sẵn
        // trong thư viện (tạo bởi app khác hoặc phiên bản cũ) còn sync_id = 0.
        try? execSQL(db, "UPDATE album SET sync_id = abs(random()), keep_local = 1 WHERE sync_id = 0")
        try? execSQL(db, "UPDATE album_artist SET sync_id = abs(random()), keep_local = 1 WHERE sync_id = 0")
        try? execSQL(db, "UPDATE item_artist SET sync_id = abs(random()), keep_local = 1 WHERE sync_id = 0")
    }
}

enum MediaLibraryAudioFormat {
    private static func fourCC(_ str: String) -> Int {
        let padded = Array(str.utf8) + Array(repeating: 0x20, count: max(0, 4 - str.utf8.count))
        var val = 0
        for i in 0..<4 { val = (val << 8) | Int(padded[i]) }
        return val
    }

    static func forExtension(_ ext: String) -> Int {
        switch ext.lowercased() {
        case "mp3": return 301
        case "flac": return fourCC("fLaC")
        case "opus": return fourCC("opus")
        case "m4a", "aac", "m4r": return fourCC("aac ")
        case "alac": return fourCC("alac")
        case "wav", "wave": return fourCC("WAVE")
        default: return 0
        }
    }
}

extension String {
    var sqlEscaped: String {
        replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "'", with: "''")
    }
}

func execSQL(_ db: OpaquePointer?, _ sql: String) throws {
    var errMsg: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
        let error = errMsg.map { String(cString: $0) } ?? "lỗi không rõ"
        sqlite3_free(errMsg)
        throw AddSongError.schemaUnexpected(error)
    }
}
