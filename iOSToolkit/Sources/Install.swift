import AVFoundation
import Network
import UIKit

/// Cài IPA trực tiếp lên máy: mở máy chủ cục bộ 127.0.0.1 rồi gọi itms-services (giống Feather/Asspp).
/// IPA từ App Store còn nguyên chữ ký Apple nên không cần chứng chỉ.
final class LocalInstaller: @unchecked Sendable {
    static let shared = LocalInstaller()
    private let queue = DispatchQueue(label: "ioskit.installer")
    private var listener: NWListener?
    private var ipaPath = ""
    private var bg: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    var onSent: (() -> Void)?

    private var manifest = ""

    func install(ipa: URL, bundleID: String, name: String, version: String, completion: @escaping (String?) -> Void) {
        stop()
        ipaPath = ipa.path
        LocalTLS.identity { [weak self] ident, err in
            guard let self else { return }
            if let err { Diag.log("TLS cục bộ: \(err) → dùng HTTP + api.palera.in") }
            self.startServer(ident: ident, bundleID: bundleID, name: name, version: version, completion: completion)
        }
    }

    private func startServer(ident: sec_identity_t?, bundleID: String, name: String, version: String, completion: @escaping (String?) -> Void) {
        let params: NWParameters
        if let ident {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, ident)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else {
            DispatchQueue.main.async { completion("Không mở được máy chủ cục bộ.") }
            return
        }
        queue.sync { listener = l }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        var fired = false
        l.stateUpdateHandler = { [weak self] st in
            guard let self, !fired else { return }
            switch st {
            case .ready:
                fired = true
                let port = l.port?.rawValue ?? 0
                self.open(port: port, secure: ident != nil, bundleID: bundleID, name: name, version: version, completion: completion)
            case let .failed(e):
                fired = true
                Diag.log("máy chủ cục bộ lỗi: \(e)")
                DispatchQueue.main.async { completion("Máy chủ cục bộ bị lỗi.") }
            default: break
            }
        }
        l.start(queue: queue)
    }

    private func open(port: UInt16, secure: Bool, bundleID: String, name: String, version: String, completion: @escaping (String?) -> Void) {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let base = secure ? "https://\(LocalTLS.host):\(port)" : "http://127.0.0.1:\(port)"
        let ipaURL = base + "/app.ipa"
        manifest = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>\(esc(ipaURL))</string></dict></array><key>metadata</key><dict><key>bundle-identifier</key><string>\(esc(bundleID))</string><key>bundle-version</key><string>\(esc(version))</string><key>kind</key><string>software</string><key>title</key><string>\(esc(name))</string></dict></dict></array></dict></plist>
        """
        let manifestURL: String
        if secure {
            manifestURL = base + "/manifest.plist"
        } else {
            let b64 = Data(ipaURL.utf8).base64EncodedString()
            manifestURL = "https://api.palera.in/genPlist?bundleid=\(enc(bundleID))&name=\(enc(name))&version=\(enc(version))&fetchurl=\(enc(b64))"
        }
        guard let url = URL(string: "itms-services://?action=download-manifest&url=" + enc(manifestURL)) else {
            DispatchQueue.main.async { completion("Không tạo được liên kết cài đặt.") }
            return
        }
        Diag.log("cài đặt: \(secure ? "HTTPS" : "HTTP") \(base)")
        DispatchQueue.main.async {
            self.bg = UIApplication.shared.beginBackgroundTask { [weak self] in self?.stop() }
            self.startKeepAlive()
            UIApplication.shared.open(url, options: [:]) { ok in completion(ok ? nil : "iOS từ chối mở liên kết cài đặt.") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1200) { [weak self] in self?.stop() }
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        player?.stop(); player = nil
        if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
    }

    // Phát âm thanh im lặng để iOS không treo app khi đang truyền file lớn lúc app ở nền.
    private func startKeepAlive() {
        var wav = Data()
        let rate: UInt32 = 8000, samples = 8000
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        wav.append(contentsOf: Array("RIFF".utf8)); wav.append(contentsOf: le32(UInt32(36 + samples * 2)))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); wav.append(contentsOf: le32(16)); wav.append(contentsOf: le16(1)); wav.append(contentsOf: le16(1))
        wav.append(contentsOf: le32(rate)); wav.append(contentsOf: le32(rate * 2)); wav.append(contentsOf: le16(2)); wav.append(contentsOf: le16(16))
        wav.append(contentsOf: Array("data".utf8)); wav.append(contentsOf: le32(UInt32(samples * 2)))
        wav.append(Data(count: samples * 2))
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: wav)
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.play()
    }

    // MARK: HTTP

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let first = req.components(separatedBy: "\r\n").first ?? ""
            if first.contains("/manifest.plist") {
                self.send(c, status: "200 OK", headers: "Content-Type: text/xml\r\n", body: Data(self.manifest.utf8)); return
            }
            guard first.contains("/app.ipa"), let size = (try? FileManager.default.attributesOfItem(atPath: self.ipaPath)[.size]) as? UInt64 else {
                self.send(c, status: "404 Not Found", headers: "", body: Data()); return
            }
            let head = first.hasPrefix("HEAD")
            var start: UInt64 = 0, end = size == 0 ? 0 : size - 1, partial = false
            if let r = req.range(of: #"(?i)range:\s*bytes=(\d*)-(\d*)"#, options: .regularExpression) {
                let nums = req[r].components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { UInt64($0) }
                let line = String(req[r])
                if line.contains("=-"), let n = nums.first { start = size > n ? size - n : 0; partial = true }
                else if let a = nums.first { start = a; if nums.count > 1 { end = min(nums[1], end) }; partial = true }
            }
            guard start <= end || size == 0 else { self.send(c, status: "416 Range Not Satisfiable", headers: "", body: Data()); return }
            let length = size == 0 ? 0 : end - start + 1
            var h = "Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\n"
            if partial { h += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
            let headData = Data(("HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n" + h + "Connection: close\r\n\r\n").utf8)
            if head { c.send(content: headData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
            guard let fh = FileHandle(forReadingAtPath: self.ipaPath) else { self.send(c, status: "404 Not Found", headers: "", body: Data()); return }
            try? fh.seek(toOffset: start)
            c.send(content: headData, completion: .contentProcessed { [weak self] err in
                if err != nil { c.cancel(); return }
                self?.stream(c, fh: fh, remaining: length, whole: !partial)
            })
        }
    }

    private func stream(_ c: NWConnection, fh: FileHandle, remaining: UInt64, whole: Bool) {
        let n = Int(min(remaining, 256 * 1024))
        let chunk = n > 0 ? ((try? fh.read(upToCount: n)) ?? Data()) : Data()
        if chunk.isEmpty {
            try? fh.close()
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                c.cancel()
                if whole { DispatchQueue.main.async { self?.onSent?() } }
            })
            return
        }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { try? fh.close(); c.cancel(); return }
            self?.stream(c, fh: fh, remaining: remaining - UInt64(chunk.count), whole: whole)
        })
    }

    private func send(_ c: NWConnection, status: String, headers: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var all = Data(head.utf8); all.append(body)
        c.send(content: all, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
