import Foundation

/// Báo cho hệ thống/app Nhạc biết là thư viện vừa thay đổi, để nó tự làm mới mà không cần khởi
/// động lại iPhone (dù theo kinh nghiệm ByeTunes thì không phải lúc nào cũng ăn ngay 100% — nên
/// giao diện vẫn nên gợi ý khởi động lại iPhone nếu app Nhạc chưa thấy bài mới).
typealias NotificationProxyClientHandle = OpaquePointer

extension DeviceSyncManager {
    @discardableResult
    func connectNotificationProxyClient(_ client: inout NotificationProxyClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            return notification_proxy_connect_rsd(rpAdapter, rpHandshake, &client)
        }
        return notification_proxy_connect(provider, &client)
    }

    /// Khởi động service notification_proxy qua lockdownd — bước "đánh thức" tối thiểu, giống
    /// ByeTunes dùng sau khi ghi database xong.
    func sendSyncFinishedNotification() {
        var lockdownd: LockdowndClientHandle?
        let err = connectLockdownClient(&lockdownd)
        guard err == IdeviceSuccess, let lockdownd else { return }
        var port: UInt16 = 0
        var ssl: Bool = false
        _ = lockdownd_start_service(lockdownd, "com.apple.mobile.notification_proxy", &port, &ssl)
        lockdownd_client_free(lockdownd)
    }

    /// Gửi thêm các thông báo "sync" thật sự qua notification_proxy — bản thân iOS dùng các thông
    /// báo này để biết itunes_control vừa được 1 "máy tính" cập nhật.
    func postLibraryRefreshNotifications() {
        var client: NotificationProxyClientHandle?
        let err = connectNotificationProxyClient(&client)
        guard err == IdeviceSuccess, let client else { return }
        defer { notification_proxy_client_free(client) }

        let notifications = [
            "com.apple.itunes-mobdev.syncWillStart",
            "com.apple.itunes-mobdev.syncDidStart",
            "com.apple.itunes-mobdev.syncDidFinish"
        ]
        for name in notifications {
            _ = name.withCString { cName in notification_proxy_post(client, cName) }
        }
    }
}
