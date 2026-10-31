import Foundation
import Darwin

// MARK: - Kết nối + heartbeat giữ phiên sống
extension DeviceSyncManager {
    func resetConnectionHandles() {
        if let oldProvider = provider {
            idevice_provider_free(oldProvider)
            provider = nil
        }
        if let oldHandshake = rpHandshake {
            rsd_handshake_free(oldHandshake)
            rpHandshake = nil
        }
        if let oldAdapter = rpAdapter {
            adapter_close(oldAdapter)
            adapter_free(oldAdapter)
            rpAdapter = nil
        }
    }

    func canStillReachDevice() -> Bool {
        guard hasActiveTransport else { return false }
        var probeClient: HeartbeatClientHandle?
        let err = connectHeartbeatClient(&probeClient)
        guard err == IdeviceSuccess, let probeClient else { return false }
        heartbeat_client_free(probeClient)
        return true
    }

    func makeSocketAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        inet_pton(AF_INET, DEVICE_HOST, &addr.sin_addr)
        return addr
    }

    @discardableResult
    func connectHeartbeatClient(_ client: inout HeartbeatClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            return heartbeat_connect_rsd(rpAdapter, rpHandshake, &client)
        }
        return heartbeat_connect(provider, &client)
    }

    @discardableResult
    func connectLockdownClient(_ client: inout LockdowndClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            return lockdownd_connect_rsd(rpAdapter, rpHandshake, &client)
        }
        return lockdownd_connect(provider, &client)
    }

    /// Kết nối AFC (Apple File Conduit) — dịch vụ cho phép đọc/ghi file trong vùng media của
    /// thiết bị (ảnh, nhạc…), tách biệt khỏi sandbox của app. Thử lại vài lần vì ngay sau khi
    /// đường hầm RPPairing vừa dựng xong, dịch vụ AFC đôi khi cần một chút thời gian mới sẵn sàng.
    @discardableResult
    func connectAfcClient(_ client: inout AfcClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            var lastError: IdeviceErrorCode = IdeviceSuccess
            for attempt in 0..<10 {
                lastError = afc_client_connect_rsd(rpAdapter, rpHandshake, &client)
                if lastError == IdeviceSuccess && client != nil { return lastError }
                if attempt < 9 { Thread.sleep(forTimeInterval: 0.2) }
            }
            return lastError
        }
        return afc_client_connect(provider, &client)
    }

    /// Dựng "đường hầm" RemotePairing (iOS 26.4 trở lên): đọc tệp RP pairing, tìm cổng dịch vụ
    /// RemotePairing qua Bonjour trên mạng cục bộ (RemotePairingDiscovery), rồi bắt tay (handshake).
    func establishRPPairingTunnel() -> Bool {
        var rpPairingPtr: RpPairingFileHandle?
        let readErr = rp_pairing_file_read(rpPairingFile.path, &rpPairingPtr)
        guard readErr == IdeviceSuccess, let rpPairingHandle = rpPairingPtr else {
            self.logOnce("[DeviceSync] LỖI: không đọc được tệp RP Pairing. Mã: \(String(describing: readErr))", key: "connection_status")
            return false
        }
        defer { rp_pairing_file_free(rpPairingHandle) }

        let resolvedPort = RemotePairingDiscovery.resolvePort() ?? RP_PAIRING_PORT
        if resolvedPort != RP_PAIRING_PORT {
            self.logOnce("[DeviceSync] Tìm thấy dịch vụ RPPairing ở cổng \(resolvedPort) qua Bonjour (mặc định \(RP_PAIRING_PORT))", key: "connection_status")
        }

        var addr = makeSocketAddress(port: resolvedPort)
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let tunnelErr = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                tunnel_create_rppairing(
                    sockaddrPointer, addrLen, "iOSToolkit-DeviceSync", rpPairingHandle, nil, nil, &rpAdapter, &rpHandshake
                )
            }
        }

        guard tunnelErr == nil, rpAdapter != nil, rpHandshake != nil else {
            if let err = tunnelErr {
                let msg = err.pointee.message != nil ? String(cString: err.pointee.message!) : "không có thông tin"
                self.logOnce("[DeviceSync] LỖI: dựng đường hầm RPPairing thất bại. Mã: \(err.pointee.code), mã phụ: \(err.pointee.sub_code), thông báo: \(msg)", key: "connection_status")
                idevice_error_free(err)
            } else {
                self.logOnce("[DeviceSync] LỖI: dựng đường hầm RPPairing thất bại (không rõ nguyên nhân)", key: "connection_status")
            }
            resetConnectionHandles()
            return false
        }

        self.logOnce("[DeviceSync] Đã dựng đường hầm RPPairing qua \(DEVICE_HOST):\(resolvedPort)", key: "connection_status")
        return true
    }

    func startHeartbeat(forceReconnect: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if !forceReconnect {
            if connectionStatus == "Đang kết nối…" {
                completion?(false)
                return
            }
            let timeSinceLastAttempt = Date().timeIntervalSince(lastHeartbeatAttemptStartedAt)
            if connectionStatus != "Đang kết nối…" && !heartbeatReady {
                guard timeSinceLastAttempt >= 10.0 else {
                    completion?(false)
                    return
                }
            }
        }

        reconnectCoordinationLock.lock()
        if isReconnecting {
            if let completion { pendingReconnectCompletions.append(completion) }
            reconnectCoordinationLock.unlock()
            return
        }
        isReconnecting = true
        reconnectCoordinationLock.unlock()

        func finish(_ success: Bool) {
            reconnectCoordinationLock.lock()
            isReconnecting = false
            let waiters = pendingReconnectCompletions
            pendingReconnectCompletions = []
            reconnectCoordinationLock.unlock()
            completion?(success)
            for waiter in waiters { waiter(success) }
        }

        heartbeatSessionID &+= 1
        refreshExpectedPairingFileState()
        guard hasValidExpectedPairingFile else {
            let message = "\(expectedPairingFileTitle) không hợp lệ"
            Diag.log("[DeviceSync] \(message). Nhập đúng tệp trước khi kết nối.")
            DispatchQueue.main.async {
                self.connectionStatus = message
                self.heartbeatReady = false
                finish(false)
            }
            return
        }

        if !forceReconnect && heartbeatReady && hasActiveTransport && canStillReachDevice() {
            DispatchQueue.main.async { finish(true) }
            return
        }

        lastHeartbeatAttemptStartedAt = Date()
        if Thread.isMainThread {
            self.connectionStatus = "Đang kết nối…"
            self.heartbeatReady = false
        } else {
            DispatchQueue.main.async {
                self.connectionStatus = "Đang kết nối…"
                self.heartbeatReady = false
            }
        }

        resetConnectionHandles()

        heartbeatThread = Thread {
            let sessionID = self.heartbeatSessionID
            let outcomeLock = NSLock()
            var outcomeReported = false
            let outcomeSemaphore = DispatchSemaphore(value: 0)

            func reportOutcome(success: Bool) {
                outcomeLock.lock()
                let alreadyReported = outcomeReported
                outcomeReported = true
                outcomeLock.unlock()
                guard !alreadyReported else { return }

                DispatchQueue.main.async {
                    guard sessionID == self.heartbeatSessionID else { return }
                    self.connectionStatus = success ? "Mất kết nối" : "Kết nối thất bại"
                    self.heartbeatReady = false
                }
            }

            self.establishHeartbeat { success in
                reportOutcome(success: success)
                outcomeSemaphore.signal()
            }

            if outcomeSemaphore.wait(timeout: .now() + self.heartbeatEstablishTimeout) == .timedOut {
                Diag.log("[DeviceSync] Hết giờ chờ thiết lập heartbeat sau \(Int(self.heartbeatEstablishTimeout))s; coi như thất bại.")
                reportOutcome(success: false)
            }
        }
        heartbeatThread?.name = "DeviceSyncHeartbeat"
        heartbeatThread?.start()

        let sessionIDForPoll = heartbeatSessionID
        DispatchQueue.global().async {
            let pollInterval: TimeInterval = 0.5
            let maxIterations = Int((self.heartbeatEstablishTimeout + 2) / pollInterval)
            for _ in 0..<maxIterations {
                if self.heartbeatReady && self.hasActiveTransport {
                    DispatchQueue.main.async { finish(true) }
                    return
                }
                guard sessionIDForPoll == self.heartbeatSessionID else {
                    DispatchQueue.main.async { finish(false) }
                    return
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
            DispatchQueue.main.async { finish(false) }
        }
    }

    func stopHeartbeat() {
        heartbeatSessionID &+= 1
        resetConnectionHandles()
        DispatchQueue.main.async {
            self.connectionStatus = "Chưa kết nối"
            self.heartbeatReady = false
        }
    }

    func establishHeartbeat(_ completion: @escaping (Bool) -> Void) {
        let sessionID = heartbeatSessionID

        if requiresRPPairingTunnel {
            guard establishRPPairingTunnel() else {
                completion(false)
                return
            }
        } else {
            var addr = makeSocketAddress(port: UInt16(LOCKDOWN_PORT))

            var pairingPtr: IdevicePairingFile?
            let pairingErr = idevice_pairing_file_read(regularPairingFile.path, &pairingPtr)
            guard pairingErr == IdeviceSuccess, pairingPtr != nil else {
                self.logOnce("[DeviceSync] LỖI: không đọc được tệp pairing. Mã: \(String(describing: pairingErr))", key: "connection_status")
                completion(false)
                return
            }

            let providerErr = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    idevice_tcp_provider_new(sockaddrPointer, pairingPtr, "iOSToolkit-DeviceSync", &provider)
                }
            }

            if provider == nil {
                self.logOnce("[DeviceSync] LỖI: provider rỗng. Mã: \(String(describing: providerErr))", key: "connection_status")
                completion(false)
                return
            }
        }

        var hbClient: HeartbeatClientHandle?
        let err = connectHeartbeatClient(&hbClient)

        guard err == IdeviceSuccess && hbClient != nil else {
            self.logOnce("[DeviceSync] LỖI: kết nối heartbeat thất bại", key: "connection_status")
            resetConnectionHandles()
            completion(false)
            return
        }

        self.logOnce("[DeviceSync] Heartbeat kết nối thành công!", key: "connection_status")

        DispatchQueue.main.async {
            self.connectionStatus = "Đã kết nối"
            self.heartbeatReady = true
        }

        runHeartbeatMonitorLoop(sessionID: sessionID, initialClient: hbClient)

        if sessionID == heartbeatSessionID {
            resetConnectionHandles()
            completion(true)
        }
    }

    func runHeartbeatMonitorLoop(sessionID: UInt64, initialClient: HeartbeatClientHandle?) {
        var client = initialClient
        var consecutivePoloFailures = 0
        var marcoInterval: UInt64 = 10

        while !Thread.current.isCancelled && sessionID == heartbeatSessionID {
            var newInterval: UInt64 = 0
            let marcoErr = heartbeat_get_marco(client, marcoInterval, &newInterval)

            guard marcoErr == IdeviceSuccess else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            if newInterval > 0 { marcoInterval = newInterval }

            let poloErr = heartbeat_send_polo(client)
            if poloErr == IdeviceSuccess {
                consecutivePoloFailures = 0
                DispatchQueue.main.async {
                    guard sessionID == self.heartbeatSessionID else { return }
                    if !self.heartbeatReady {
                        self.heartbeatReady = true
                        self.connectionStatus = "Đã kết nối"
                    }
                }
            } else {
                consecutivePoloFailures += 1
                Diag.log("[DeviceSync] Heartbeat polo thất bại (\(consecutivePoloFailures)).")

                if consecutivePoloFailures >= 3 {
                    Diag.log("[DeviceSync] Heartbeat không phản hồi; kết nối lại heartbeat, giữ nguyên phần còn lại.")
                    heartbeat_client_free(client)

                    var freshClient: HeartbeatClientHandle?
                    let reconnectErr = connectHeartbeatClient(&freshClient)
                    guard reconnectErr == IdeviceSuccess, freshClient != nil else {
                        Diag.log("[DeviceSync] Không kết nối lại được heartbeat trên transport hiện tại; coi như mất kết nối.")
                        return
                    }

                    Diag.log("[DeviceSync] Heartbeat đã kết nối lại; giữ nguyên transport.")
                    client = freshClient
                    consecutivePoloFailures = 0
                    marcoInterval = 10
                }
            }
        }

        heartbeat_client_free(client)
    }
}
