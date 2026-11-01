import Foundation
import SQLite3

/// "Dọn nhạc": liệt kê các bài hát hiện có trong thư viện Apple Music của thiết bị và cho phép xoá
/// 1 bài — xoá cả hàng database (và các bảng liên quan: nghệ sĩ/album/thể loại/ảnh bìa mồ côi nếu
/// không còn bài nào khác dùng tới) lẫn tệp âm thanh vật lý trên thiết bị.
struct DeviceLibrarySong: Identifiable {
    var id: Int64 { itemPid }
    let itemPid: Int64
    let title: String
    let artist: String
    let album: String
    let remoteDirectory: String
    let remoteFilename: String
}

extension DeviceSyncManager {
    /// CHỈ ĐỌC: liệt kê tối đa `limit` bài hát (sắp theo tên) để người dùng chọn xoá.
    func listLibrarySongs(limit: Int = 500, completion: @escaping (Result<[DeviceLibrarySong], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            guard connectErr == IdeviceSuccess, let afc else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.afcConnectFailed)) }
                return
            }
            defer { afc_client_free(afc) }

            guard let mainData = self.afcReadFile(afc, remotePath: Self.mediaLibraryRemotePath) else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.mainDatabaseMissing)) }
                return
            }
            let walData = self.afcReadFile(afc, remotePath: "\(Self.mediaLibraryRemotePath)-wal")
            let shmData = self.afcReadFile(afc, remotePath: "\(Self.mediaLibraryRemotePath)-shm")

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("liblist-\(UUID().uuidString)", isDirectory: true)
            let dbURL = tempDir.appendingPathComponent(Self.mediaLibraryRemoteName)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try mainData.write(to: dbURL)
                if let walData { try walData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryRemoteName)-wal")) }
                if let shmData { try shmData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryRemoteName)-shm")) }
            } catch {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.downloadFailed(error.localizedDescription))) }
                return
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if db != nil { sqlite3_close(db) }
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.cannotOpenDatabase("không mở được"))) }
                return
            }
            defer { sqlite3_close(db) }

            var songs: [DeviceLibrarySong] = []
            let query = """
                SELECT item.item_pid, item_extra.title, item_artist.item_artist, album.album,
                       base_location.path, item_extra.location
                FROM item
                LEFT JOIN item_extra ON item.item_pid = item_extra.item_pid
                LEFT JOIN item_artist ON item.item_artist_pid = item_artist.item_artist_pid
                LEFT JOIN album ON item.album_pid = album.album_pid
                LEFT JOIN base_location ON item.base_location_id = base_location.base_location_id
                WHERE item.media_type = 8
                ORDER BY item_extra.title COLLATE NOCASE
                LIMIT \(limit)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let pid = sqlite3_column_int64(stmt, 0)
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "(không tên)"
                    let artist = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let album = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let basePath = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "iTunes_Control/Music/F00"
                    let location = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    guard !location.isEmpty else { continue }
                    let normalizedBase = basePath.hasPrefix("/") ? basePath : "/\(basePath)"
                    songs.append(DeviceLibrarySong(itemPid: pid, title: title, artist: artist, album: album, remoteDirectory: normalizedBase, remoteFilename: location))
                }
            }
            sqlite3_finalize(stmt)

            DispatchQueue.main.async { completion(.success(songs)) }
        }
    }

    /// Xoá 1 bài hát: xoá tệp âm thanh vật lý + toàn bộ hàng database liên quan, dọn luôn nghệ
    /// sĩ/album/thể loại/ảnh bìa không còn bài nào khác tham chiếu tới (giống ByeTunes).
    func deleteSong(_ song: DeviceLibrarySong, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ result: Result<Void, Error>) { DispatchQueue.main.async { completion(result) } }

            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            guard connectErr == IdeviceSuccess, let afc else {
                finish(.failure(LibraryInfoError.afcConnectFailed)); return
            }
            defer { afc_client_free(afc) }

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
            defer { sqlite3_close(db) }

            _ = Self.sqliteExecRaw(db, "BEGIN IMMEDIATE TRANSACTION")
            let success = Self.removeLibraryRowsAndResidue(db, itemPids: [song.itemPid])
            _ = Self.sqliteExecRaw(db, success ? "COMMIT" : "ROLLBACK")
            guard success else {
                finish(.failure(AddSongError.schemaUnexpected("xoá hàng database thất bại, đã rollback")))
                return
            }

            do {
                try self.commitMediaLibrary(afc, localDbURL: staged.dbURL)
            } catch {
                finish(.failure(error)); return
            }

            let remotePath = "\(song.remoteDirectory)/\(song.remoteFilename)"
            _ = self.afcRemoveFile(afc, remotePath: remotePath)

            self.sendSyncFinishedNotification()
            self.postLibraryRefreshNotifications()
            finish(.success(()))
        }
    }

    fileprivate static func sqliteExecRaw(_ db: OpaquePointer?, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Xoá hàng của 1 bài + dọn rác (album/nghệ sĩ/thể loại/ảnh bìa không còn ai tham chiếu) —
    /// cùng logic ByeTunes dùng, port gần như nguyên văn (chỉ đổi sang không phụ thuộc Logger).
    fileprivate static func removeLibraryRowsAndResidue(_ db: OpaquePointer?, itemPids: [Int64]) -> Bool {
        let tempTables = ["_del", "_touched_album", "_touched_iartist", "_touched_aartist", "_touched_genre", "_gone", "_tok"]
        func dropTempTables() {
            for table in tempTables { _ = sqliteExecRaw(db, "DROP TABLE IF EXISTS temp.\(table)") }
        }
        dropTempTables()
        defer { dropTempTables() }

        guard sqliteExecRaw(db, "CREATE TEMP TABLE _del(item_pid INTEGER PRIMARY KEY)") else { return false }
        for pid in itemPids {
            guard sqliteExecRaw(db, "INSERT OR IGNORE INTO _del VALUES (\(pid))") else { return false }
        }

        let itemRowTables = ["item", "item_extra", "item_playback", "item_stats", "item_store", "item_video", "item_search", "lyrics", "chapter"]
        let statements: [String] = [
            "CREATE TEMP TABLE _touched_album AS SELECT DISTINCT album_pid p FROM item WHERE item_pid IN (SELECT item_pid FROM _del);",
            "CREATE TEMP TABLE _touched_iartist AS SELECT DISTINCT item_artist_pid p FROM item WHERE item_pid IN (SELECT item_pid FROM _del);",
            "CREATE TEMP TABLE _touched_aartist AS SELECT DISTINCT album_artist_pid p FROM item WHERE item_pid IN (SELECT item_pid FROM _del);",
            "CREATE TEMP TABLE _touched_genre AS SELECT DISTINCT genre_id p FROM item WHERE item_pid IN (SELECT item_pid FROM _del);",
            "DELETE FROM item WHERE item_pid IN (SELECT item_pid FROM _del);",
            "CREATE TEMP TABLE _gone(p INTEGER PRIMARY KEY);",
            "INSERT OR IGNORE INTO _gone SELECT item_pid FROM _del;",
            "INSERT OR IGNORE INTO _gone SELECT album_pid FROM album WHERE (album_pid IN (SELECT p FROM _touched_album) OR album_artist_pid IN (SELECT p FROM _touched_aartist)) AND NOT EXISTS (SELECT 1 FROM item WHERE item.album_pid=album.album_pid);",
            "INSERT OR IGNORE INTO _gone SELECT item_artist_pid FROM item_artist WHERE item_artist_pid IN (SELECT p FROM _touched_iartist) AND NOT EXISTS (SELECT 1 FROM item WHERE item.item_artist_pid=item_artist.item_artist_pid);",
            "INSERT OR IGNORE INTO _gone SELECT album_artist_pid FROM album_artist WHERE album_artist_pid IN (SELECT p FROM _touched_aartist) AND NOT EXISTS (SELECT 1 FROM item WHERE item.album_artist_pid=album_artist.album_artist_pid) AND NOT EXISTS (SELECT 1 FROM album WHERE album.album_artist_pid=album_artist.album_artist_pid AND album.album_pid NOT IN (SELECT p FROM _gone));",
            "CREATE TEMP TABLE _tok(t TEXT PRIMARY KEY);",
            "INSERT OR IGNORE INTO _tok SELECT artwork_token FROM artwork_token WHERE entity_pid IN (SELECT p FROM _gone) AND artwork_token!='';",
            "INSERT OR IGNORE INTO _tok SELECT available_artwork_token FROM best_artwork_token WHERE entity_pid IN (SELECT p FROM _gone) AND available_artwork_token!='';",
            "INSERT OR IGNORE INTO _tok SELECT fetchable_artwork_token FROM best_artwork_token WHERE entity_pid IN (SELECT p FROM _gone) AND fetchable_artwork_token!='';",
        ] + itemRowTables.filter { $0 != "item" }.map {
            "DELETE FROM \($0) WHERE item_pid IN (SELECT item_pid FROM _del);"
        } + [
            "DELETE FROM artwork_token WHERE entity_pid IN (SELECT p FROM _gone);",
            "DELETE FROM best_artwork_token WHERE entity_pid IN (SELECT p FROM _gone);",
            "DELETE FROM album WHERE album_pid IN (SELECT p FROM _gone);",
            "DELETE FROM item_artist WHERE item_artist_pid IN (SELECT p FROM _gone);",
            "DELETE FROM album_artist WHERE album_artist_pid IN (SELECT p FROM _gone);",
            "DELETE FROM genre WHERE genre_id IN (SELECT p FROM _touched_genre) AND NOT EXISTS (SELECT 1 FROM item WHERE item.genre_id=genre.genre_id);",
            "DELETE FROM artwork WHERE artwork_token IN (SELECT t FROM _tok) AND artwork_token NOT IN (SELECT artwork_token FROM artwork_token) AND artwork_token NOT IN (SELECT available_artwork_token FROM best_artwork_token) AND artwork_token NOT IN (SELECT fetchable_artwork_token FROM best_artwork_token WHERE fetchable_artwork_token!='');"
        ]
        return statements.allSatisfy { sqliteExecRaw(db, $0) }
    }
}
