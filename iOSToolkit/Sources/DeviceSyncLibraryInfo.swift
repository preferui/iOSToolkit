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

    /// Tải một tệp từ AFC về Data trong bộ nhớ, dùng chính AFC client đang truyền vào (để dùng lại
    /// 1 kết nối cho nhiều tệp — tránh mở/đóng AFC liên tục). Trả về nil nếu tệp không tồn tại
    /// (bình thường với -wal/-shm nếu Apple Music chưa ghi gì dở dang) hoặc đọc lỗi.
    private func downloadFileFromDevice(_ afc: AfcClientHandle, remotePath: String) -> Data? {
        var file: AfcFileHandle?
        let openErr = afc_file_open(afc, remotePath, AfcRdOnly, &file)
        guard openErr == IdeviceSuccess, let file else {
            if let openErr { idevice_error_free(openErr) }
            return nil
        }
        var dataPtr: UnsafeMutablePointer<UInt8>?
        var length = 0
        let readErr = afc_file_read_entire(file, &dataPtr, &length)
        afc_file_close(file)
        guard readErr == IdeviceSuccess, let dataPtr, length > 0 else {
            if let readErr { idevice_error_free(readErr) }
            return nil
        }
        let data = Data(bytes: dataPtr, count: length)
        afc_file_read_data_free(dataPtr, length)
        return data
    }

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

            guard let mainData = self.downloadFileFromDevice(
                afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)"
            ) else {
                DispatchQueue.main.async { completion(.failure(LibraryInfoError.mainDatabaseMissing)) }
                return
            }
            let walData = self.downloadFileFromDevice(afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)-wal")
            let shmData = self.downloadFileFromDevice(afc, remotePath: "\(Self.mediaLibraryDirectory)/\(Self.mediaLibraryFilename)-shm")

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
