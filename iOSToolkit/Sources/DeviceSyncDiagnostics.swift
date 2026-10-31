import Foundation

/// Các phép kiểm tra an toàn (chỉ đọc hoặc ghi 1 tệp thử nghiệm rồi xoá ngay) để xác nhận cả
/// lockdown lẫn AFC đều hoạt động thật trên thiết bị, trước khi đụng tới phần ghi dữ liệu nhạc
/// thật (rủi ro cao hơn nhiều vì đụng tới database thư viện Apple Music).
extension DeviceSyncManager {
    /// Đọc phiên bản iOS trực tiếp từ thiết bị qua lockdownd (không liên quan iOS của chính
    /// iPhone đang chạy app — đây là cách xác nhận kênh lockdown thật sự nói chuyện được).
    func fetchDeviceProductVersion() -> String? {
        var lockdownd: LockdowndClientHandle?
        let err = connectLockdownClient(&lockdownd)
        guard err == IdeviceSuccess, let client = lockdownd else { return nil }
        defer { lockdownd_client_free(client) }

        var plist: plist_t?
        let valErr = lockdownd_get_value(client, "ProductVersion", nil, &plist)
        guard valErr == IdeviceSuccess, let versionPlist = plist else { return nil }
        defer { plist_free(versionPlist) }

        var cString: UnsafeMutablePointer<CChar>?
        plist_get_string_val(versionPlist, &cString)
        guard let cString else { return nil }
        let version = String(cString: cString)
        plist_mem_free(cString)
        return version
    }

    /// Ghi một tệp nhỏ vào AFC (vùng media của thiết bị, KHÔNG phải sandbox app), đọc lại để so
    /// sánh nội dung, rồi xoá ngay — xác nhận AFC đọc/ghi được hai chiều mà không chạm gì tới
    /// dữ liệu thật của người dùng.
    func runAfcRoundTripTest(completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            guard connectErr == IdeviceSuccess, let afc else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "DeviceSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không kết nối được AFC (mã: \(String(describing: connectErr)))."])))
                }
                return
            }
            defer { afc_client_free(afc) }

            let remotePath = "/iostoolkit-afc-test.txt"
            let payload = "iOS Toolkit AFC test \(UUID().uuidString)"
            let payloadData = Data(payload.utf8)

            var writeHandle: AfcFileHandle?
            let openWriteErr = afc_file_open(afc, remotePath, AfcWrOnly, &writeHandle)
            guard openWriteErr == IdeviceSuccess, let writeHandle else {
                let msg = openWriteErr?.pointee.message != nil ? String(cString: openWriteErr!.pointee.message!) : "không rõ"
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "DeviceSync", code: -2, userInfo: [NSLocalizedDescriptionKey: "Mở tệp để ghi thất bại: \(msg)"])))
                }
                return
            }
            payloadData.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    afc_file_write(writeHandle, base, payloadData.count)
                }
            }
            afc_file_close(writeHandle)

            var readHandle: AfcFileHandle?
            let openReadErr = afc_file_open(afc, remotePath, AfcRdOnly, &readHandle)
            guard openReadErr == IdeviceSuccess, let readHandle else {
                let msg = openReadErr?.pointee.message != nil ? String(cString: openReadErr!.pointee.message!) : "không rõ"
                _ = afc_remove_path(afc, remotePath)
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "DeviceSync", code: -3, userInfo: [NSLocalizedDescriptionKey: "Ghi xong nhưng mở lại để đọc thất bại: \(msg)"])))
                }
                return
            }
            var dataPtr: UnsafeMutablePointer<UInt8>?
            var length = 0
            let readErr = afc_file_read_entire(readHandle, &dataPtr, &length)
            afc_file_close(readHandle)
            _ = afc_remove_path(afc, remotePath)

            guard readErr == IdeviceSuccess, let dataPtr, length > 0 else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "DeviceSync", code: -4, userInfo: [NSLocalizedDescriptionKey: "Đọc lại tệp vừa ghi thất bại hoặc rỗng."])))
                }
                return
            }
            let readBack = String(decoding: Data(bytes: dataPtr, count: length), as: UTF8.self)
            afc_file_read_data_free(dataPtr, length)

            let version = self.fetchDeviceProductVersion() ?? "(không đọc được)"
            let ok = readBack == payload
            DispatchQueue.main.async {
                if ok {
                    completion(.success("AFC đọc/ghi OK (đã xoá tệp thử). iOS thiết bị: \(version)."))
                } else {
                    completion(.failure(NSError(domain: "DeviceSync", code: -5, userInfo: [NSLocalizedDescriptionKey: "Đọc lại được nhưng nội dung không khớp — có gì đó bất thường."])))
                }
            }
        }
    }
}
