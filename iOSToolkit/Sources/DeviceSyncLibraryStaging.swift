import Foundation
import SQLite3

/// Tải MediaLibrary.sqlitedb (+ -wal/-shm) về máy để sửa cục bộ, rồi đẩy ngược lên thiết bị bằng
/// kiểu "tráo an toàn" (atomic-ish swap): tải bản mới lên với tên `.temp`, đổi tên bản hiện tại
/// thành `.backup`, đổi tên `.temp` thành tên chính thức, chỉ xoá `.backup` khi mọi bước trên đều
/// thành công. Nếu có lỗi ở bước đổi tên cuối, bản `.backup` được phục hồi lại — thư viện nhạc thật
/// của người dùng không bao giờ bị để ở trạng thái "giữa chừng" nếu có sự cố giữa chừng.
struct StagedMediaLibrary {
    let tempDir: URL
    let dbURL: URL
}

enum LibraryWriteError: LocalizedError {
    case afcConnectFailed
    case mainDatabaseMissing
    case integrityCheckFailed(String)
    case stageFailed(String)
    case uploadFailed
    case swapFailed

    var errorDescription: String? {
        switch self {
        case .afcConnectFailed:
            return "Không kết nối được AFC."
        case .mainDatabaseMissing:
            return "Không tải được MediaLibrary.sqlitedb từ thiết bị."
        case .integrityCheckFailed(let detail):
            return "Database thư viện nhạc có vẻ không toàn vẹn (\(detail)) — dừng lại để không ghi đè lên database lỗi. Hãy thử mở app Nhạc trên máy rồi thử lại."
        case .stageFailed(let detail):
            return "Chuẩn bị database cục bộ thất bại: \(detail)"
        case .uploadFailed:
            return "Tải database đã sửa lên thiết bị thất bại."
        case .swapFailed:
            return "Không kích hoạt được database mới trên thiết bị (đã phục hồi bản cũ nếu có)."
        }
    }
}

extension DeviceSyncManager {
    static let mediaLibraryRemoteDir = "/iTunes_Control/iTunes"
    static let mediaLibraryRemoteName = "MediaLibrary.sqlitedb"
    static let mediaLibraryRemotePath = "\(mediaLibraryRemoteDir)/\(mediaLibraryRemoteName)"

    /// Tải MediaLibrary.sqlitedb(+wal/shm) hiện tại của thiết bị về một thư mục tạm, checkpoint WAL
    /// vào tệp chính rồi kiểm tra toàn vẹn (PRAGMA quick_check) trước khi cho phép sửa — nếu
    /// database đang hỏng sẵn, DỪNG LẠI thay vì sửa tiếp lên trên một nền móng lỗi.
    func stageMediaLibraryForWriting(_ afc: AfcClientHandle) throws -> StagedMediaLibrary {
        guard let mainData = afcReadFile(afc, remotePath: Self.mediaLibraryRemotePath) else {
            throw LibraryWriteError.mainDatabaseMissing
        }
        let walData = afcReadFile(afc, remotePath: "\(Self.mediaLibraryRemotePath)-wal")
        let shmData = afcReadFile(afc, remotePath: "\(Self.mediaLibraryRemotePath)-shm")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("libwrite-\(UUID().uuidString)", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent(Self.mediaLibraryRemoteName)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try mainData.write(to: dbURL)
            if let walData, !walData.isEmpty {
                try walData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryRemoteName)-wal"))
            }
            if let shmData, !shmData.isEmpty {
                try shmData.write(to: tempDir.appendingPathComponent("\(Self.mediaLibraryRemoteName)-shm"))
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw LibraryWriteError.stageFailed(error.localizedDescription)
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            try? FileManager.default.removeItem(at: tempDir)
            throw LibraryWriteError.stageFailed("không mở được database vừa tải về")
        }
        if walData != nil {
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        }
        var integrityStmt: OpaquePointer?
        var integrityOK = false
        var integrityResult = "unknown"
        if sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &integrityStmt, nil) == SQLITE_OK {
            if sqlite3_step(integrityStmt) == SQLITE_ROW, let text = sqlite3_column_text(integrityStmt, 0) {
                integrityResult = String(cString: text)
                integrityOK = integrityResult == "ok"
            }
        }
        sqlite3_finalize(integrityStmt)
        sqlite3_close(db)

        guard integrityOK else {
            try? FileManager.default.removeItem(at: tempDir)
            throw LibraryWriteError.integrityCheckFailed(integrityResult)
        }

        return StagedMediaLibrary(tempDir: tempDir, dbURL: dbURL)
    }

    /// Đẩy database cục bộ (đã sửa) lên thiết bị theo kiểu tráo an toàn mô tả ở trên.
    func commitMediaLibrary(_ afc: AfcClientHandle, localDbURL: URL) throws {
        sqlite3_exec_checkpointAndClose(localDbURL)

        let tempDBPath = "\(Self.mediaLibraryRemotePath).temp"
        let finalDBPath = Self.mediaLibraryRemotePath
        let shmPath = "\(Self.mediaLibraryRemotePath)-shm"
        let walPath = "\(Self.mediaLibraryRemotePath)-wal"
        let backupDBPath = "\(finalDBPath).backup"

        guard afcUploadFile(afc, localURL: localDbURL, remotePath: tempDBPath) else {
            throw LibraryWriteError.uploadFailed
        }

        _ = afc_remove_path(afc, shmPath)
        _ = afc_remove_path(afc, walPath)
        _ = afc_remove_path(afc, backupDBPath)

        var info = AfcFileInfo()
        let hasExistingFinal = afc_get_file_info(afc, finalDBPath, &info) == nil
        if hasExistingFinal { afc_file_info_free(&info) }

        if hasExistingFinal {
            guard afc_rename_path(afc, finalDBPath, backupDBPath) == IdeviceSuccess else {
                _ = afc_remove_path(afc, tempDBPath)
                throw LibraryWriteError.swapFailed
            }
        }

        if afc_rename_path(afc, tempDBPath, finalDBPath) == IdeviceSuccess {
            if hasExistingFinal { _ = afc_remove_path(afc, backupDBPath) }
            return
        }

        if hasExistingFinal {
            _ = afc_rename_path(afc, backupDBPath, finalDBPath)
        }
        _ = afc_remove_path(afc, tempDBPath)
        throw LibraryWriteError.swapFailed
    }
}

/// Checkpoint WAL vào tệp .sqlitedb chính rồi đóng lại gọn gàng trước khi tải lên — tránh đẩy lên
/// thiết bị một tệp .sqlitedb chưa chứa hết thay đổi (còn nằm ở -wal cục bộ).
private func sqlite3_exec_checkpointAndClose(_ dbURL: URL) {
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        if db != nil { sqlite3_close(db) }
        return
    }
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)
    sqlite3_close(db)
}
