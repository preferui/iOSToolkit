import Foundation
import Darwin
import Combine
import UIKit

// MARK: - Kiểu dữ liệu cầu nối tới idevice-ffi (Rust)
//
// idevice-ffi (https://github.com/jkcoxson/idevice) là một thư viện Rust mã nguồn mở, bản thay
// thế hiện đại cho libimobiledevice, biên dịch thành libidevice_ffi.a ngay trong CI (xem
// .github/workflows/ios-toolkit.yml). Header idevice.h sinh ra từ bước build đó khai báo mọi
// hàm/hằng số C dùng ở đây (idevice_pairing_file_read, heartbeat_connect, LOCKDOWN_PORT, Info,
// Disabled, struct IdeviceFfiError, …) — không cần khai báo lại trong Swift.
//
// Cơ chế hoạt động: bình thường một app trong sandbox của iOS không thể tự nói chuyện với các
// service nội bộ của chính thiết bị nó (lockdownd, RemotePairing…) — việc đó chỉ máy tính đã
// "ghép cặp" (pair) với thiết bị mới làm được. idevice-ffi giả lập đúng vai trò "máy tính đã
// ghép cặp" đó bằng một "pairing file" xuất sẵn từ máy tính, rồi tự kết nối qua mạng tới địa chỉ
// cố định 10.7.0.1 — địa chỉ mà một app VPN cục bộ khác (ví dụ LocalDevVPN) tạo ra để đại diện
// cho chính thiết bị. Vì vậy tính năng này CẦN CẢ pairing file lẫn app VPN đó đang chạy, không
// chỉ riêng iOS Toolkit.

typealias IdevicePairingFile = OpaquePointer
typealias IdeviceProviderHandle = OpaquePointer
typealias HeartbeatClientHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer
typealias AfcClientHandle = OpaquePointer
typealias AfcFileHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias RpPairingFileHandle = OpaquePointer

typealias IdeviceErrorCode = UnsafeMutablePointer<IdeviceFfiError>?
let IdeviceSuccess: IdeviceErrorCode = nil

enum PairingFileImportError: LocalizedError {
    case invalidFileType(expected: String)
    case wrongFormatForOSVersion(expected: String, detectedOther: String)

    var errorDescription: String? {
        switch self {
        case .invalidFileType(let expected):
            return "Tệp này không phải \(expected) hợp lệ. Hãy xuất lại đúng tệp rồi thử lại."
        case .wrongFormatForOSVersion(let expected, let detectedOther):
            return "Tệp này có vẻ là \(detectedOther), nhưng phiên bản iOS hiện tại của máy cần \(expected). Hãy xuất đúng loại tệp rồi thử lại."
        }
    }
}

/// Địa chỉ IP cố định của "thiết bị" khi app tự kết nối tới chính nó qua app VPN cục bộ.
let DEVICE_HOST = "10.7.0.1"
let RP_PAIRING_PORT: UInt16 = 49152

/// Trạng thái kết nối + quản lý tệp pairing. Đây là phần nền tảng — CHƯA bao gồm đồng bộ nhạc,
/// đó sẽ là bước tiếp theo sau khi phần kết nối này được xác nhận chạy được trên máy thật.
final class DeviceSyncManager: ObservableObject {
    static let shared = DeviceSyncManager()

    @Published var heartbeatReady: Bool = false
    @Published var connectionStatus: String = "Chưa kết nối"
    @Published var hasValidExpectedPairingFile: Bool = false

    var provider: IdeviceProviderHandle?
    var rpAdapter: AdapterHandle?
    var rpHandshake: RsdHandshakeHandle?
    var heartbeatThread: Thread?
    var heartbeatSessionID: UInt64 = 0
    var isReconnecting = false
    var pendingReconnectCompletions: [(Bool) -> Void] = []
    let reconnectCoordinationLock = NSLock()

    var autoReconnectTimer: DispatchSourceTimer?
    var lastHeartbeatAttemptStartedAt: Date = .distantPast
    let autoReconnectCheckInterval: TimeInterval = 2
    let staleHeartbeatAttemptInterval: TimeInterval = 6
    let heartbeatEstablishTimeout: TimeInterval = 20

    private var lastLoggedStatus: [String: String] = [:]

    func logOnce(_ message: String, key: String) {
        objc_sync_enter(self)
        let changed = lastLoggedStatus[key] != message
        if changed { lastLoggedStatus[key] = message }
        objc_sync_exit(self)
        if changed { Diag.log(message) }
    }

    // MARK: - Tệp pairing
    private var storageDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceSync", isDirectory: true)
    }

    var regularPairingFile: URL { storageDirectory.appendingPathComponent("pairingFile.plist") }
    var rpPairingFile: URL { storageDirectory.appendingPathComponent("rpPairingFile.plist") }
    var expectedPairingFile: URL { requiresRPPairingTunnel ? rpPairingFile : regularPairingFile }

    /// iOS 26.4 trở lên đổi sang cơ chế "RP pairing" (RemotePairing) — cần loại tệp pairing khác
    /// với các bản iOS cũ hơn dùng lockdown pairing "cổ điển".
    var requiresRPPairingTunnel: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion > 26 { return true }
        return v.majorVersion == 26 && v.minorVersion >= 4
    }

    var expectedPairingFileTitle: String { requiresRPPairingTunnel ? "Tệp RP Pairing" : "Tệp Pairing" }

    var hasActiveTransport: Bool {
        requiresRPPairingTunnel ? (rpAdapter != nil && rpHandshake != nil) : provider != nil
    }

    private init() {
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("idevice-logs.txt").path
        let cString = strdup(logPath)
        defer { free(cString) }
        idevice_init_logger(Info, Disabled, cString)

        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        refreshExpectedPairingFileState()
        installAutoReconnectWatcher()
    }

    /// Tự thử kết nối lại định kỳ khi app đang mở và đã có tệp pairing hợp lệ, thay vì bắt người
    /// dùng tự bấm "Kết nối" mỗi lần vào app.
    func installAutoReconnectWatcher() {
        guard autoReconnectTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + autoReconnectCheckInterval, repeating: autoReconnectCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard UIApplication.shared.applicationState == .active else { return }

            self.refreshExpectedPairingFileState()
            guard self.hasValidExpectedPairingFile else {
                self.logOnce("[DeviceSync] Bỏ qua tự kết nối lại: chưa có tệp pairing hợp lệ", key: "auto_reconnect")
                return
            }

            let timeSinceLastAttempt = Date().timeIntervalSince(self.lastHeartbeatAttemptStartedAt)
            let connectingIsStale = self.connectionStatus == "Đang kết nối…"
                && timeSinceLastAttempt >= self.staleHeartbeatAttemptInterval

            guard self.connectionStatus != "Đang kết nối…" || connectingIsStale else { return }

            if self.connectionStatus != "Đang kết nối…" {
                guard timeSinceLastAttempt >= 10.0 else { return }
            }

            let needsReconnect = !self.heartbeatReady || !self.hasActiveTransport
            guard needsReconnect else { return }

            self.logOnce("[DeviceSync] Tự kết nối lại", key: "auto_reconnect")
            self.startHeartbeat(forceReconnect: true)
        }
        timer.resume()
        autoReconnectTimer = timer
    }
}

extension FileManager {
    func createDirectoryLogged(at url: URL) {
        do {
            try createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Diag.log("[DeviceSync] Không tạo được thư mục \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
