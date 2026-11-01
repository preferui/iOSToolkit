import Foundation

/// Các hàm AFC đọc/ghi/tạo-thư-mục dùng chung cho mọi tính năng đụng tới file trên thiết bị
/// (tóm tắt thư viện, thêm bài hát, xoá bài hát…) — gom lại một chỗ để không viết lặp lại.
extension DeviceSyncManager {
    /// Đọc toàn bộ nội dung 1 tệp từ AFC. Trả về nil nếu tệp không tồn tại hoặc đọc lỗi (bình
    /// thường với -wal/-shm khi chưa có thay đổi dở dang).
    func afcReadFile(_ afc: AfcClientHandle, remotePath: String) -> Data? {
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

    /// Ghi toàn bộ Data lên 1 đường dẫn AFC (ghi đè nếu đã tồn tại).
    @discardableResult
    func afcWriteData(_ afc: AfcClientHandle, _ data: Data, remotePath: String) -> Bool {
        var file: AfcFileHandle?
        let openErr = afc_file_open(afc, remotePath, AfcWrOnly, &file)
        guard openErr == IdeviceSuccess, let file else {
            if let openErr { idevice_error_free(openErr) }
            return false
        }
        var writeOK = true
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                let writeErr = afc_file_write(file, base, data.count)
                if writeErr != IdeviceSuccess {
                    writeOK = false
                    if let writeErr { idevice_error_free(writeErr) }
                }
            }
        }
        afc_file_close(file)
        return writeOK
    }

    /// Ghi 1 tệp local lên thiết bị qua AFC.
    @discardableResult
    func afcUploadFile(_ afc: AfcClientHandle, localURL: URL, remotePath: String) -> Bool {
        guard let data = try? Data(contentsOf: localURL) else { return false }
        return afcWriteData(afc, data, remotePath: remotePath)
    }

    /// Tạo thư mục trên thiết bị nếu chưa có (bỏ qua lỗi "đã tồn tại").
    func afcEnsureDirectory(_ afc: AfcClientHandle, path: String) {
        _ = afc_make_directory(afc, path)
    }

    /// Xoá 1 tệp trên thiết bị, trả về true nếu AFC báo thành công hoặc tệp vốn không tồn tại.
    @discardableResult
    func afcRemoveFile(_ afc: AfcClientHandle, remotePath: String) -> Bool {
        let err = afc_remove_path(afc, remotePath)
        return err == IdeviceSuccess
    }
}
