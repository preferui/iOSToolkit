import ApplePackage
import Foundation

// MARK: - Lỗi

enum StoreError: LocalizedError {
    case invalidRedirect
    case response(Int)
    case emptyResponse(Int)
    case invalidPackage
    case empty
    case catalogUnavailable
    case actionRequired
    case noVersions
    case license
    case rejected(String, String)
    case badDownload(Int)
    case responseBody(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidRedirect: return "Apple trả về địa chỉ chuyển hướng không hợp lệ."
        case let .response(s), let .emptyResponse(s): return "Máy chủ tải của Apple trả về phản hồi không hợp lệ (HTTP \(s))."
        case .invalidPackage: return "Apple trả về thông tin gói không đầy đủ hoặc không khớp."
        case .empty: return "Apple không trả về gói tải nào. Có thể tài khoản này chưa từng nhận app, sai vùng (quốc gia) của tài khoản, hoặc cần chọn đúng ID phiên bản."
        case .catalogUnavailable: return "Không xác định được phiên bản hiện tại của app. Hãy nhập ID phiên bản cụ thể (bấm “Liệt kê phiên bản”)."
        case .actionRequired: return "Apple yêu cầu xác nhận tài khoản. Hãy mở App Store bằng tài khoản này, hoàn tất các bước xác nhận rồi thử lại."
        case .noVersions: return "Apple không trả về danh sách phiên bản cho app này."
        case .license: return "Tài khoản này chưa có giấy phép (chưa từng nhận/mua) app này nên không tải được."
        case let .rejected(code, msg): return msg.isEmpty ? "Apple từ chối yêu cầu (mã \(code))." : msg
        case let .badDownload(s): return "Tải file thất bại (HTTP \(s))."
        case let .responseBody(s, b): return "Apple trả về HTTP \(s)" + (b.isEmpty ? "." : ": \(b)")
        }
    }
}

// MARK: - Giao thức tải (theo ipatool / ApplePackage)

enum StoreProto {
    enum Endpoint: String {
        case volumeStore, redownload, update
        var versionKey: String { self == .volumeStore ? "externalVersionId" : "appExtVrsId" }
        var path: String {
            switch self {
            case .volumeStore: return "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
            case .redownload: return "/r/redownload"
            case .update: return "/up/updateProduct"
            }
        }
    }

    static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func plist(_ data: Data) -> [String: Any]? {
        var payload = data
        if let xml = String(data: data, encoding: .utf8), let start = xml.range(of: "<plist"), let end = xml.range(of: "</plist>"), start.lowerBound < end.upperBound {
            payload = Data(xml[start.lowerBound ..< end.upperBound].utf8)
        }
        return (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [String: Any]
    }

    static func cookieDomain(_ d: String?) -> String? { d.map { String($0.drop(while: { $0 == "." })).lowercased() } }

    static func validatedURL(_ url: URL) throws -> URL {
        let host = url.host?.lowercased() ?? ""
        let storeHost = host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
        let storePath = [Endpoint.volumeStore.path, "/WebObjects/MZFinance.woa/wa/redownloadProduct"].contains(url.path)
        guard url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil, url.port == nil || url.port == 443,
              (storeHost && storePath) || (host == "downloaddispatch.itunes.apple.com" && [Endpoint.redownload.path, Endpoint.update.path].contains(url.path))
        else { throw StoreError.invalidRedirect }
        return url
    }

    static func payload(endpoint: Endpoint, appID: Int64, guid: String, version: String?) -> [String: Any] {
        var r: [String: Any] = ["creditDisplay": "", "guid": guid, "salableAdamId": appID, "serialNumber": "0"]
        if let version, !version.isEmpty { r[endpoint.versionKey] = version }
        return r
    }

    static func failureCode(_ r: [String: Any]) -> String {
        let f = string(r["failureType"])
        if !f.isEmpty { return f }
        let code = string((r["metrics"] as? [String: Any])?["messageCode"])
        return code == "0" ? "" : code
    }

    static func fallbackReason(_ r: [String: Any]) -> String? {
        let f = failureCode(r)
        if f == "5002" { return "failure-5002" }
        guard f.isEmpty, string(r["customerMessage"]).isEmpty, r["dialog"] == nil, r["action"] == nil else { return nil }
        let st = string(r["status"])
        guard st.isEmpty || st == "0" else { return nil }
        if let items = r["songList"] as? [Any] { return items.isEmpty ? "empty-songList" : nil }
        return r["songList"] == nil ? "missing-songList" : nil
    }

    static func packageItem(_ r: [String: Any], version: String?) throws -> [String: Any] {
        let code = failureCode(r)
        let message = string(r["customerMessage"])
        if !code.isEmpty { throw StoreError.rejected(code, message) }
        guard let items = r["songList"] as? [[String: Any]], !items.isEmpty else {
            if !message.isEmpty { throw StoreError.rejected("", message) }
            if r["dialog"] != nil || r["action"] != nil { throw StoreError.actionRequired }
            let st = string(r["status"])
            if !st.isEmpty, st != "0" { throw StoreError.rejected(st, "") }
            throw StoreError.empty
        }
        let item = items[0]
        guard let metadata = item["metadata"] as? [String: Any] else { throw StoreError.invalidPackage }
        let returned = string(metadata["softwareVersionExternalIdentifier"])
        if let version, !version.isEmpty, !returned.isEmpty, returned != version { throw StoreError.invalidPackage }
        return item
    }
}

// MARK: - Kết quả

struct StorePackage {
    var url: String
    var sinfs: [Sinf]
    var iTunesMetadata: Data
    var version: String
    var build: String
    var bundleID: String
    var name: String
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Client

enum StoreClient {
    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }

    private static func fetch(session: URLSession, endpoint: StoreProto.Endpoint, account: inout Account, appID: Int64, version: String?) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = endpoint == .volumeStore ? Configuration.storeAPIHost(pod: account.pod) : "downloaddispatch.itunes.apple.com"
        comps.path = endpoint.path
        if endpoint == .update {
            let bag = try? await Bag.fetchBag()
            guard let update = bag?.updateEndpoint, let adv = URLComponents(url: update, resolvingAgainstBaseURL: false) else { throw StoreError.emptyResponse(500) }
            comps = adv
        }
        comps.queryItems = [URLQueryItem(name: "guid", value: Configuration.deviceIdentifier)]
        guard var url = comps.url else { throw StoreError.invalidRedirect }
        let body = try PropertyListSerialization.data(fromPropertyList: StoreProto.payload(endpoint: endpoint, appID: appID, guid: Configuration.deviceIdentifier, version: version), format: .xml, options: 0)
        for hop in 0 ... 3 {
            try Task.checkCancellation()
            url = try StoreProto.validatedURL(url)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            req.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
            req.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
            req.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
            for (name, value) in account.cookie.buildCookieHeader(url) { req.setValue(value, forHTTPHeaderField: name) }
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw StoreError.response(0) }
            mergeCookies(http, url: url, account: &account)
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard hop < 3, let loc = http.value(forHTTPHeaderField: "Location"), let next = URL(string: loc, relativeTo: url)?.absoluteURL else { throw StoreError.invalidRedirect }
                url = try StoreProto.validatedURL(next)
                continue
            }
            let plist = StoreProto.plist(data)
            guard http.statusCode == 200, let plist else {
                if data.isEmpty { throw StoreError.emptyResponse(http.statusCode) }
                var snip = String(data: data.prefix(400), encoding: .utf8) ?? ""
                snip = snip.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                Diag.log("store \(endpoint.rawValue) HTTP \(http.statusCode): \(snip.prefix(200))")
                throw StoreError.responseBody(http.statusCode, String(snip.prefix(160)))
            }
            return plist
        }
        throw StoreError.invalidRedirect
    }

    private static func mergeCookies(_ response: HTTPURLResponse, url: URL, account: inout Account) {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields { if let ks = k as? String, let vs = v as? String { headers[ks] = vs } }
        for c in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = StoreProto.cookieDomain(c.domain)
            account.cookie.removeAll { $0.name == c.name && $0.path == c.path && StoreProto.cookieDomain($0.domain) == domain }
            if let exp = c.expiresDate, exp <= Date() { continue }
            account.cookie.append(Cookie(name: c.name, value: c.value, path: c.path, domain: domain, expiresAt: c.expiresDate?.timeIntervalSince1970, httpOnly: c.isHTTPOnly, secure: c.isSecure))
        }
    }

    private static func catalogVersion(session: URLSession, appID: Int64, region: String) async throws -> String {
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: "enterprisestore"),
            URLQueryItem(name: "cc", value: region.lowercased()), URLQueryItem(name: "l", value: "en"),
        ]
        var req = URLRequest(url: url.url!)
        req.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let item = results[String(appID)] as? [String: Any],
              let offers = item["offers"] as? [[String: Any]]
        else { throw StoreError.catalogUnavailable }
        for offer in offers {
            let v = offer["version"] as? [String: Any]
            var id = StoreProto.string(v?["externalId"])
            if id.isEmpty, let p = offer["buyParams"] as? String { id = URLComponents(string: "?" + p)?.queryItems?.first { $0.name == "appExtVrsId" }?.value ?? "" }
            if !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) { return id }
        }
        throw StoreError.catalogUnavailable
    }

    /// Lấy "item" gói tải; volumeStore trước, rồi redownload/update khi cần.
    private static func product(account: inout Account, appID: Int64, version: String?) async throws -> [String: Any] {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let version = (version?.isEmpty ?? true) ? nil : version
        var effective = version
        var primary: [String: Any] = [:]
        var primaryFailed = false
        var primaryError: Error?
        do {
            primary = try await fetch(session: session, endpoint: .volumeStore, account: &account, appID: appID, version: version)
        } catch StoreError.responseBody(let st, let body) where st == 403 || st == 404 {
            // Đã thấy với app đã gỡ: thử đường tải lại (redownload) thay vì dừng.
            Diag.log("volumeStore lỗi \(st), thử redownload")
            primaryFailed = true
            primaryError = StoreError.responseBody(st, body)
        }
        var response = primary
        if primaryFailed || StoreProto.fallbackReason(primary) != nil {
            var resolved = version ?? ""
            if resolved.isEmpty {
                guard let region = Configuration.countryCode(for: account.store) else { throw primaryError ?? StoreError.catalogUnavailable }
                do { resolved = try await catalogVersion(session: session, appID: appID, region: region) } catch { throw primaryError ?? StoreError.catalogUnavailable }
            }
            effective = resolved
            do {
                response = try await fetch(session: session, endpoint: .redownload, account: &account, appID: appID, version: resolved)
            } catch StoreError.emptyResponse(500) {
                response = try await fetch(session: session, endpoint: .update, account: &account, appID: appID, version: resolved)
            }
        }
        if StoreProto.failureCode(response) == "9610" { throw StoreError.license }
        return try StoreProto.packageItem(response, version: effective)
    }

    static func package(account: inout Account, appID: Int64, version: String?) async throws -> StorePackage {
        let email = account.email
        let item = try await product(account: &account, appID: appID, version: version)
        guard let url = item["URL"] as? String, let asset = URL(string: url), ["https", "http"].contains(asset.scheme ?? ""), asset.host != nil,
              var metadata = item["metadata"] as? [String: Any],
              let ver = metadata["bundleShortVersionString"] as? String,
              let build = metadata["bundleVersion"] as? String,
              let sigs = item["sinfs"] as? [[String: Any]], !sigs.isEmpty
        else { throw StoreError.invalidPackage }
        var sinfs: [Sinf] = []
        for s in sigs {
            guard let id = s["id"] as? Int64, let data = s["sinf"] as? Data else { throw StoreError.invalidPackage }
            sinfs.append(Sinf(id: id, sinf: data))
        }
        metadata["apple-id"] = email
        metadata["userName"] = email
        let bundle = StoreProto.string(metadata["softwareVersionBundleId"])
        let name = StoreProto.string(metadata["itemName"])
        let md = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        return StorePackage(url: url, sinfs: sinfs, iTunesMetadata: md, version: ver, build: build, bundleID: bundle, name: name)
    }

    static func versions(account: inout Account, appID: Int64) async throws -> [String] {
        let item = try await product(account: &account, appID: appID, version: nil)
        guard let md = item["metadata"] as? [String: Any], let ids = md["softwareVersionExternalIdentifiers"] as? [Any] else { throw StoreError.noVersions }
        let list = ids.map { StoreProto.string($0) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { throw StoreError.noVersions }
        return list
    }
}

// MARK: - Tải file có tiến độ

final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?
    private var lastTick: CFAbsoluteTime = 0

    func download(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        self.onProgress = onProgress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            self.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTick > 0.15 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastTick = now
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard let c = continuation else { return }
        continuation = nil
        if status != 200 { c.resume(throwing: StoreError.badDownload(status)); return }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            c.resume(returning: dest)
        } catch { c.resume(throwing: error) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let c = continuation { continuation = nil; c.resume(throwing: error) }
    }
}
