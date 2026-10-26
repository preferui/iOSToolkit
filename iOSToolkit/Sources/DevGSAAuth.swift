//
//  DevGSAAuth.swift
//  iOSToolkit
//
//  Đăng nhập Apple ID kiểu "Developer" (giao thức GrandSlam/GSA mà Xcode/SideStore
//  dùng), tự viết dựa trên các sự kiện/endpoint công khai của Apple, chỉ dùng
//  GSACryptoKit (thư viện ngoài, AGPLv3) cho phần toán học SRP-6a + mã hoá.
//
//  Phạm vi hiện tại: đăng nhập + xác thực 2 lớp (2FA) -> lấy được "app token" cho
//  dịch vụ Xcode (com.apple.gs.xcode.auth). CHƯA xin chứng chỉ / ký lại app — đó là
//  bước tiếp theo sau khi phần đăng nhập này được người dùng xác nhận chạy ổn.
//
//  ⚠️ Chưa được thử nghiệm trên máy thật — cần kiểm tra kỹ với tài khoản Apple ID
//  thật trước khi dùng cho việc gia hạn app.
//

import Foundation
import GSACryptoKit

enum DevGSAError: LocalizedError {
    case cryptoInitFailed
    case badServerResponse(String)
    case incorrectCredentials(String?)
    case incorrectVerificationCode(String?)
    case serverProofMismatch
    case missingField(String)
    case appSpecificPasswordRequired
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .cryptoInitFailed: return "Không khởi tạo được phiên SRP."
        case .badServerResponse(let s): return "Phản hồi không hợp lệ từ Apple: \(s)"
        case .incorrectCredentials(let m): return m ?? "Sai Apple ID hoặc mật khẩu."
        case .incorrectVerificationCode(let m): return m ?? "Mã xác thực không đúng."
        case .serverProofMismatch: return "Xác thực máy chủ thất bại (M2 không khớp) — có thể bị can thiệp giữa đường."
        case .missingField(let f): return "Phản hồi của Apple thiếu trường '\(f)'."
        case .appSpecificPasswordRequired: return "Tài khoản này yêu cầu mật khẩu dành riêng cho ứng dụng (app-specific password)."
        case .network(let e): return "Lỗi mạng: \(e.localizedDescription)"
        }
    }
}

/// Kênh gửi mã xác thực 2 lớp.
enum DevTwoFactorChannel: Equatable {
    case trustedDevice
    case sms(phoneID: String)
}

/// Trạng thái "đang chờ nhập mã 2FA" — giữ lại mọi thứ cần để: (a) gửi/yêu cầu mã,
/// (b) xác minh mã, và sau đó (c) đăng nhập lại từ đầu (Apple yêu cầu lặp lại bước
/// SRP sau khi máy đã được tin cậy qua 2FA).
struct DevTwoFactorContext {
    let appleID: String
    let password: String
    let dsid: String
    let idmsToken: String
    let anisetteHeaders: [String: String]
    let trustedPhoneIDs: [String]
}

struct DevAppleSession {
    let appleID: String
    let dsid: String
    let appToken: String
    let anisetteHeaders: [String: String]
}

enum DevSRPLoginOutcome {
    case success(DevAppleSession)
    case twoFactorRequired(DevTwoFactorContext)
}

/// Thực hiện toàn bộ luồng GrandSlam Authentication (GSA) bằng SRP-6a, tự viết lại
/// dựa trên các hằng số/endpoint công khai của Apple — không copy mã của bên thứ ba.
enum DevGSAAuth {

    // Apple GrandSlam — các endpoint này là địa chỉ công khai, không phải bí mật.
    private static let grandSlamAuthURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    private static let grandSlamValidateURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!
    private static let trustedDeviceRequestURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
    private static func smsPutURL(mode: String) -> URL { URL(string: "https://gsa.apple.com/auth/verify/phone/put?mode=\(mode)")! }
    private static let phoneSecurityCodeURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode?referrer=/auth/verify/phone/put")!

    // Dịch vụ mục tiêu: xin token cho Xcode (đây là app mà Developer Portal/Xcode
    // dùng để xác thực mọi thao tác ký app, xin chứng chỉ, v.v.)
    private static let targetApp = "com.apple.gs.xcode.auth"

    // MARK: - Bước 1: Đăng nhập SRP

    static func performSRPLogin(appleID rawAppleID: String, password: String, anisetteHeaders: [String: String]) async throws -> DevSRPLoginOutcome {
        let appleID = rawAppleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let srp = SRPClient(), let publicKeyA = srp.startAuthentication() else {
            throw DevGSAError.cryptoInitFailed
        }

        let clientDict = clientDictionary(anisetteHeaders: anisetteHeaders)

        // "init": gửi public key A, nhận lại salt + iterations + public key B của Apple
        let initRequest: [String: Any] = [
            "A2k": publicKeyA, "cpd": clientDict, "ps": ["s2k", "s2k_fo"], "o": "init", "u": appleID
        ]
        let initResp = try await sendGrandSlam(initRequest, anisetteHeaders: anisetteHeaders)

        guard let c = initResp["c"] as? String,
              let salt = initResp["s"] as? Data,
              let iterations = initResp["i"] as? Int,
              let serverPublicKeyB = initResp["B"] as? Data else {
            throw DevGSAError.badServerResponse("thiếu c/s/i/B ở bước init")
        }

        let useHexDigest = (initResp["sp"] as? String) == "s2k_fo"
        guard let pwData = password.data(using: .utf8), let pwDigest = CryptoUtilities.sha256(pwData) else {
            throw DevGSAError.badServerResponse("không băm được mật khẩu")
        }
        let pbkdfInput = useHexDigest ? Data(pwDigest.map { String(format: "%02x", $0) }.joined().utf8) : pwDigest
        guard let derivedKey = CryptoUtilities.pbkdf2SHA256(password: pbkdfInput, salt: salt, rounds: iterations, outputLength: pwDigest.count) else {
            throw DevGSAError.badServerResponse("PBKDF2 thất bại")
        }

        guard let m1 = srp.processChallenge(username: appleID, password: derivedKey, salt: salt, serverPublicKey: serverPublicKeyB) else {
            throw DevGSAError.badServerResponse("SRP processChallenge thất bại")
        }

        // "complete": gửi M1, Apple trả về dữ liệu đã mã hoá (spd) + bằng chứng máy chủ (M2)
        let completeRequest: [String: Any] = [
            "c": c, "cpd": clientDict, "M1": m1, "o": "complete", "u": appleID
        ]
        let completeResp = try await sendGrandSlam(completeRequest, anisetteHeaders: anisetteHeaders)

        guard let spd = completeResp["spd"] as? Data else { throw DevGSAError.missingField("spd") }
        guard let m2 = completeResp["M2"] as? Data else { throw DevGSAError.missingField("M2") }
        guard srp.verifyServerProof(m2) else { throw DevGSAError.serverProofMismatch }
        guard let sessionKey = srp.sessionKey() else { throw DevGSAError.badServerResponse("thiếu session key") }

        guard let spdKey = CryptoUtilities.hmacSHA256(key: sessionKey, strings: ["extra data key:"]),
              let spdIV = CryptoUtilities.hmacSHA256(key: sessionKey, strings: ["extra data iv:"]),
              let decrypted = CryptoUtilities.aesCBCDecrypt(key: spdKey, iv: spdIV, ciphertext: spd) else {
            throw DevGSAError.badServerResponse("giải mã spd thất bại")
        }
        guard let payload = parsePlist(decrypted) else { throw DevGSAError.badServerResponse("spd không phải plist hợp lệ") }

        let dsid = (payload["adsid"] as? String) ?? (payload["dsid"] as? CustomStringConvertible)?.description
        guard let dsid else { throw DevGSAError.missingField("adsid/dsid") }
        let idmsToken = (payload["GsIdmsToken"] as? String) ?? (payload["idmsToken"] as? String)
        guard let idmsToken else { throw DevGSAError.missingField("GsIdmsToken") }

        // Có cần 2FA không?
        let status = completeResp["Status"] as? [String: Any]
        let authType = (status?["au"] as? String) ?? (completeResp["au"] as? String)
            ?? (((status?["hsc"] as? Int) == 409) ? "pushedCode" : nil)

        let twoFactorTypes: Set<String> = ["trustedDeviceSecondaryAuth", "trustedDevice", "secondaryAuth", "sms", "voice", "phone", "pushedCode"]
        if let authType, twoFactorTypes.contains(authType) {
            let phoneIDs = parseTrustedPhoneIDs(from: completeResp) + parseTrustedPhoneIDs(from: status ?? [:])
            let context = DevTwoFactorContext(
                appleID: appleID, password: password, dsid: dsid, idmsToken: idmsToken,
                anisetteHeaders: anisetteHeaders, trustedPhoneIDs: phoneIDs.isEmpty ? ["1"] : phoneIDs
            )
            return .twoFactorRequired(context)
        }

        guard let sk = payload["sk"] as? Data, let cBytes = payload["c"] as? Data else {
            throw DevGSAError.missingField("sk/c (apptokens)")
        }
        let session = try await fetchAppToken(appleID: appleID, dsid: dsid, idmsToken: idmsToken, sk: sk, c: cBytes, anisetteHeaders: anisetteHeaders)
        return .success(session)
    }

    // MARK: - Bước 2 (nếu cần): Yêu cầu & xác minh mã 2FA

    /// Yêu cầu Apple gửi mã tới thiết bị tin cậy (push) hoặc SMS.
    static func requestTwoFactorCode(channel: DevTwoFactorChannel, context: DevTwoFactorContext) async throws {
        switch channel {
        case .trustedDevice:
            var req = twoFactorRequest(url: trustedDeviceRequestURL, context: context)
            req.httpMethod = "GET"
            let (data, resp) = try await URLSession.shared.data(for: req)
            try throwIfBadStatus(resp, data: data)

        case .sms(let phoneID):
            var req = twoFactorRequest(url: smsPutURL(mode: "sms"), context: context)
            req.httpMethod = "POST"
            req.httpBody = try PropertyListSerialization.data(fromPropertyList: ["serverInfo": ["mode": "sms", "phoneNumber.id": phoneID]], format: .xml, options: 0)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try throwIfBadStatus(resp, data: data)
        }
    }

    /// Gửi mã người dùng nhập để xác minh. Nếu thành công, gọi lại `performSRPLogin`
    /// (Apple yêu cầu đăng nhập lại từ đầu sau khi thiết bị đã được tin cậy qua 2FA).
    static func submitTwoFactorCode(_ code: String, channel: DevTwoFactorChannel, context: DevTwoFactorContext) async throws {
        switch channel {
        case .trustedDevice:
            var req = twoFactorRequest(url: grandSlamValidateURL, context: context)
            req.setValue(code, forHTTPHeaderField: "security-code")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try throwIfBadStatus(resp, data: data)

        case .sms(let phoneID):
            var req = twoFactorRequest(url: phoneSecurityCodeURL, context: context)
            req.httpMethod = "POST"
            req.httpBody = try PropertyListSerialization.data(fromPropertyList: [
                "securityCode.code": code, "serverInfo": ["mode": "sms", "phoneNumber.id": phoneID]
            ], format: .xml, options: 0)
            let (data, resp) = try await URLSession.shared.data(for: req)
            // Với SMS, Apple xác nhận qua header X-Apple-PE-Token thay vì chỉ status 200.
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  http.allHeaderFields.keys.contains(where: { ($0 as? String)?.lowercased() == "x-apple-pe-token" }) else {
                let msg = (parsePlist(data)?["em"] as? String)
                throw DevGSAError.incorrectVerificationCode(msg)
            }
        }
    }

    // MARK: - Bước 3: Lấy app token (dùng về sau cho Developer Portal)

    private static func fetchAppToken(appleID: String, dsid: String, idmsToken: String, sk: Data, c: Data, anisetteHeaders: [String: String]) async throws -> DevAppleSession {
        guard let checksum = CryptoUtilities.hmacSHA256(key: sk, strings: ["apptokens", dsid, targetApp]) else {
            throw DevGSAError.badServerResponse("không tính được checksum apptokens")
        }
        let request: [String: Any] = [
            "app": [targetApp], "c": c, "checksum": checksum,
            "cpd": clientDictionary(anisetteHeaders: anisetteHeaders),
            "o": "apptokens", "t": idmsToken, "u": dsid
        ]
        let resp = try await sendGrandSlam(request, anisetteHeaders: anisetteHeaders)
        guard let encryptedToken = resp["et"] as? Data, encryptedToken.count > 35 else {
            throw DevGSAError.missingField("et")
        }
        let aad = encryptedToken.prefix(3)
        let nonce = encryptedToken.subdata(in: 3..<19)
        let ciphertext = encryptedToken.subdata(in: 19..<(encryptedToken.count - 16))
        let tag = encryptedToken.suffix(16)
        guard let tokenPlistData = CryptoUtilities.aesGCMDecrypt(key: sk, nonce: Data(nonce), aad: Data(aad), ciphertext: Data(ciphertext), tag: Data(tag)) else {
            throw DevGSAError.badServerResponse("giải mã apptoken thất bại")
        }
        guard let tokens = parsePlist(tokenPlistData),
              let appTokens = tokens["t"] as? [String: Any],
              let appEntry = appTokens[targetApp] as? [String: Any],
              let authToken = appEntry["token"] as? String else {
            throw DevGSAError.missingField("t/\(targetApp)/token")
        }
        return DevAppleSession(appleID: appleID, dsid: dsid, appToken: authToken, anisetteHeaders: anisetteHeaders)
    }

    /// Dùng lại sau khi 2FA đã xác minh: đăng nhập SRP lại từ đầu.
    static func retryLoginAfterTwoFactor(context: DevTwoFactorContext) async throws -> DevAppleSession {
        let outcome = try await performSRPLogin(appleID: context.appleID, password: context.password, anisetteHeaders: context.anisetteHeaders)
        switch outcome {
        case .success(let session): return session
        case .twoFactorRequired: throw DevGSAError.badServerResponse("vẫn yêu cầu 2FA sau khi đã xác minh — thử lại")
        }
    }

    // MARK: - Helpers dùng chung

    private static func clientDictionary(anisetteHeaders h: [String: String]) -> [String: Any] {
        [
            "bootstrap": true, "icscrec": true, "pbe": false, "prkgen": true,
            "svct": "iCloud",
            "loc": h["X-Apple-Locale"] ?? "en_US",
            "X-Apple-Locale": h["X-Apple-Locale"] ?? "en_US",
            "X-Apple-I-MD": h["X-Apple-I-MD"] ?? "",
            "X-Apple-I-MD-M": h["X-Apple-I-MD-M"] ?? "",
            "X-Mme-Device-Id": h["X-Mme-Device-Id"] ?? "",
            "X-Apple-I-MD-LU": h["X-Apple-I-MD-LU"] ?? "",
            "X-Apple-I-MD-RINFO": h["X-Apple-I-MD-RINFO"] ?? "",
            "X-Apple-I-SRL-NO": h["X-Apple-I-SRL-NO"] ?? "0",
            "X-Apple-I-Client-Time": h["X-Apple-I-Client-Time"] ?? "",
            "X-Apple-I-TimeZone": h["X-Apple-I-TimeZone"] ?? "UTC"
        ]
    }

    private static func sendGrandSlam(_ requestParams: [String: Any], anisetteHeaders: [String: String]) async throws -> [String: Any] {
        let full: [String: Any] = ["Header": ["Version": "1.0.1"], "Request": requestParams]
        let plistData = try PropertyListSerialization.data(fromPropertyList: full, format: .xml, options: 0)

        var req = URLRequest(url: grandSlamAuthURL)
        req.httpMethod = "POST"
        req.httpBody = plistData
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue(anisetteHeaders["X-Mme-Client-Info"] ?? "", forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(anisetteHeaders["User-Agent"] ?? "akd/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("close", forHTTPHeaderField: "Connection")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw DevGSAError.network(error)
        }
        guard !data.isEmpty else { throw DevGSAError.badServerResponse("phản hồi rỗng") }
        guard let full = parsePlist(data) else { throw DevGSAError.badServerResponse("không phải plist/JSON hợp lệ") }
        let dict = (full["Response"] as? [String: Any]) ?? full

        if let status = dict["Status"] as? [String: Any], let ec = status["ec"] as? Int, ec != 0 {
            let em = status["em"] as? String
            switch ec {
            case -22406: throw DevGSAError.incorrectCredentials(em)
            case -20101, -20209: throw DevGSAError.appSpecificPasswordRequired
            case -21669: throw DevGSAError.incorrectVerificationCode(em)
            default: throw DevGSAError.badServerResponse("mã lỗi Apple \(ec): \(em ?? "?")")
            }
        }
        _ = resp
        return dict
    }

    private static func twoFactorRequest(url: URL, context: DevTwoFactorContext) -> URLRequest {
        let identity = Data("\(context.dsid):\(context.idmsToken)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        let h = context.anisetteHeaders
        let headers: [String: String] = [
            "Accept": "application/x-buddyml",
            "Accept-Language": "en-us",
            "Content-Type": "application/x-plist",
            "User-Agent": "Xcode",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "16.0 (16A242d)",
            "X-Apple-Identity-Token": identity,
            "X-Apple-I-MD": h["X-Apple-I-MD"] ?? "",
            "X-Apple-I-MD-M": h["X-Apple-I-MD-M"] ?? "",
            "X-Mme-Device-Id": h["X-Mme-Device-Id"] ?? "",
            "X-MMe-Client-Info": h["X-Mme-Client-Info"] ?? "",
            "X-Apple-I-MD-LU": h["X-Apple-I-MD-LU"] ?? "",
            "X-Apple-I-MD-RINFO": h["X-Apple-I-MD-RINFO"] ?? "",
            "X-Apple-I-SRL-NO": h["X-Apple-I-SRL-NO"] ?? "0",
            "X-Apple-I-Client-Time": h["X-Apple-I-Client-Time"] ?? "",
            "X-Apple-Locale": h["X-Apple-Locale"] ?? "en_US",
            "X-Apple-I-TimeZone": h["X-Apple-I-TimeZone"] ?? "UTC",
            "Connection": "close"
        ]
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return req
    }

    private static func throwIfBadStatus(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (parsePlist(data)?["em"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
            throw DevGSAError.badServerResponse(msg)
        }
    }

    private static func parseTrustedPhoneIDs(from dict: [String: Any]) -> [String] {
        let list = (dict["trustedPhoneNumbers"] as? [[String: Any]]) ?? (dict["phoneNumbers"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? CustomStringConvertible)?.description }
    }

    private static func parsePlist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
