import Foundation
import SQLite3

/// Đọc (CHỈ ĐỌC, không ghi gì cả) database thư viện Apple Music của thiết bị để báo cáo số bài
/// hát / playlist hiện có. Đây là bước xác nhận an toàn tiếp theo trước khi đụng tới phần ghi
/// (tiêm nhạc) — bước ghi rủi ro cao hơn hẳn vì có thể làm hỏng thư viện nhạc thật của người dùng
/// nếu sai sót.
///
/// Lưu ý về schema (đã xác nhận trực tiếp từ mã nguồn tham khảo, không đoán):
/// - Bảng `item` có cột `media_type`, KHÔNG có `media_kind`.
/// - Bảng `item_extra` (khoá `item_pid`) mới có cột `media_kind` — bài hát nhạc dùng `media_kind = 1`.
/// - Bảng `container` có cột `distinguished_kind` (0 = playlist thường do người dùng tạo, khác 0 =
///   playlist hệ thống/đặc biệt như "Bài hát đã tải", "Yêu thích"…) và `contained_media_type`
///   (8 = chứa nhạc).
struct DeviceLibrarySummary {
    var iosSchemaUserVersion: Int32
    var songCount: Int
    var playlistCount: Int
}

enum LibraryInfoError: LocalizedError {
    case afcConnectFailed
    case mainDatabaseMissing
    case downloadFailed(String)
    case cannotOpenDatabase(String)

    var errorDescription: String? {
        switch self {
        case .afcConnectFailed:
            return "Không kết nối được AFC để đọc thư viện nhạc."
        case .mainDatabaseMissing:
            return "Không tải được MediaLibrary.sqlitedb từ thiết bị (có thể chưa từng mở Apple Music, hoặc đường dẫn khác)."
        case .downloadFailed(let detail):
            return "Tải tệp thư viện nhạc thất bại: \(detail)"
        case .cannotOpenDatabase(let detail):
            return "Không mở được database để đọc (chỉ đọc): \(detail)"
        }
    }
}

extension DeviceSyncManager {
    private static let mediaLibraryDirectory = "/iTunes_Control/iTunes"
    private static let mediaLibraryFilename = "MediaLibrary.sqlitedb"

    /// Đọc tóm tắt thư viện nhạc: tải MediaLibrary.sqlitedb (+ -wal/-shm nếu có, để không bỏ sót
    /// thay đổi chưa "chốt" vào tệp chính) về một thư mục tạm, mở CHỈ ĐỌC bằng SQLite3, đếm số bài
    /// hát và playlist rồi dọn dẹp ngay — không ghi gì lên thiết bị, không sửa tệp tải về.
    func fetchLibrarySummary(completion: @escaping (Result<DeviceLibrarySummary, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            guard connectErr == IdeviceSuccess, let afc else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.afcConnectFailed)) }
                return
            }
            defer { afc_client_free(afc) }

            guard let mainData = self.afcReadFile(
                afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)"
            ) else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.mainDatabaseMissing)) }
                return
            }
            let walData = self.afcReadFile(afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)-wal")
            let shmData = self.afcReadFile(afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)-shm")

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("libinfo-\(UUID().uuidString)", isDirectory: true)
            let dbURL = tempDir.appendingPathComponent(Self.mediaLibraryFilename)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try mainData.write(to: dbURL)
                if let walData {
                    try walData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryFilename)-wal"))
                }
                if let shmData {
                    try shmData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryFilename)-shm"))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.downloadFailed(error.localizedDescription))) }
                return
            }

            do {
                let summary = try Self.readSummary(fromDatabaseAt: dbURL)
                DispatchQueue.main.async { completion(.success(summary)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func readSummary(fromDatabaseAt dbURL: URL) throws -> DeviceLibrarySummary {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "mã lỗi \(openResult)"
            if db != nil { sqlite3_close(db) }
            throw LibraryInfoError.cannotOpenDatabase(msg)
        }
        defer { sqlite3_close(db) }

        let userVersion = Int32(try scalarInt(db, "PRAGMA user_version"))
        let songCount = try scalarInt(db, "SELECT COUNT(*) FROM item_extra WHERE media_kind = 1")
        let playlistCount = try scalarInt(db, "SELECT COUNT(*) FROM container WHERE contained_media_type = 8 AND distinguished_kind = 0")

        return DeviceLibrarySummary(iosSchemaUserVersion: userVersion, songCount: songCount, playlistCount: playlistCount)
    }

    /// CHẨN ĐOÁN (chỉ đọc): liệt kê vài hàng item_extra được sửa gần đây nhất, in ra đầy đủ các cột
    /// quan trọng (title, độ dài title, location, media_kind/media_type, nghệ sĩ, album) để xác
    /// nhận xem tên bài hát có thực sự được ghi đúng vào database hay không — tránh đoán mò khi
    /// app Nhạc hiển thị bất thường (ví dụ: tên bài trống dù đã thêm thành công).
    func fetchRecentItemsDebug(limit: Int = 5, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            guard connectErr == IdeviceSuccess, let afc else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.afcConnectFailed)) }
                return
            }
            defer { afc_client_free(afc) }

            guard let mainData = self.afcReadFile(
                afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)"
            ) else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.mainDatabaseMissing)) }
                return
            }
            let walData = self.afcReadFile(afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)-wal")
            let shmData = self.afcReadFile(afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)-shm")

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("libdebug-\(UUID().uuidString)", isDirectory: true)
            let dbURL = tempDir.appendingPathComponent(Self.mediaLibraryFilename)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try mainData.write(to: dbURL)
                if let walData { try walData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryFilename)-wal")) }
                if let shmData { try shmData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryFilename)-shm")) }
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

            let query = """
                SELECT item.item_pid, item_extra.title, length(item_extra.title), item_extra.location,
                       item_extra.media_kind, item.media_type,
                       item_artist.item_artist, album.album, item.in_my_library, item_extra.date_modified
                FROM item
                LEFT JOIN item_extra ON item.item_pid = item_extra.item_pid
                LEFT JOIN item_artist ON item.item_artist_pid = item_artist.item_artist_pid
                LEFT JOIN album ON item.album_pid = album.album_pid
                ORDER BY item_extra.date_modified DESC
                LIMIT \(limit)
            """
            var stmt: OpaquePointer?
            var lines: [String] = []
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let pid = sqlite3_column_int64(stmt, 0)
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    let titleLen = sqlite3_column_int(stmt, 2)
                    let location = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "(nil)"
                    let mediaKind = sqlite3_column_int(stmt, 4)
                    let mediaType = sqlite3_column_int(stmt, 5)
                    let artist = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "(nil)"
                    let album = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "(nil)"
                    let inLibrary = sqlite3_column_int(stmt, 8)
                    lines.append("""
                        item_pid=\(pid)
                          title=\(title.map { "\"\($0)\"" } ?? "(NULL)") (dài \(titleLen) ký tự)
                          location=\(location) media_kind=\(mediaKind) media_type=\(mediaType) in_my_library=\(inLibrary)
                          artist=\(artist) album=\(album)
                        """)
                }
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmt)
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.cannotOpenDatabase(msg))) }
                return
            }
            sqlite3_finalize(stmt)

            let result = lines.isEmpty ? "(không có hàng nào)" : lines.joined(separator: "\n\n")
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw LibraryInfoError.cannotOpenDatabase(msg)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw LibraryInfoError.cannotOpenDatabase(msg)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
