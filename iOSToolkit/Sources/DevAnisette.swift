//
//  DevAnisette.swift
//  iOSToolkit
//
//  Sinh dữ liệu "anisette" ngay trên máy (không cần máy tính/jailbreak), dùng cho
//  luồng đăng nhập Apple ID kiểu Developer (GrandSlam/GSA) để tự gia hạn iOS Toolkit.
//
//  Cách hoạt động:
//   - AnisetteKit (thư viện ngoài, AGPLv3) chạy thẳng 2 thư viện gốc của Apple
//     (libstoreservicescore.so, libCoreADI.so) bằng một máy ảo CPU (Unicorn Engine)
//     ngay trong app, không cần JIT, không cần jailbreak.
//   - Apple không phát hành 2 thư viện đó công khai, nên AnisetteKit không đóng gói
//     sẵn — ta phải tự tải chúng lúc chạy. Theo quyết định đã chốt với người dùng,
//     ta dùng chung hạ tầng cộng đồng mà SideStore đang dùng (máy chủ "ODA") thay vì
//     tự lưu trữ lại 2 file nhị phân đó.
//   - Dữ liệu "adi.pb" (định danh thiết bị ảo sau khi đăng ký với Apple) được lưu lại
//     trong thư mục Documents của app để lần sau không phải đăng ký lại.
//
//  Toàn bộ phần gọi mạng/giải nén ở file này là code tự viết, chỉ tham khảo các hằng
//  số/URL công khai (địa chỉ máy chủ cộng đồng) chứ không copy mã nguồn của ai.
//

import Foundation
import AnisetteKit
import ZIPFoundation

enum DevAnisetteConstants {
    // Nguồn danh sách máy chủ anisette cộng đồng của SideStore (công khai, dùng
    // đúng theo lựa chọn người dùng đã chốt: dùng chung hạ tầng SideStore).
    static let serverListURL = URL(string: "https://servers.sidestore.io/servers.json")!
    // Nếu không lấy được "oda" từ serverListURL thì rơi về thẳng URL này.
    static let fallbackODAMetadataURL = URL(string: "https://zzz.haus/oda.json")!

    static let requiredLibraryNames = AnisetteConstants.Libraries.requiredNames // libstoreservicescore.so, libCoreADI.so
}

enum DevAnisetteError: LocalizedError {
    case badServerList
    case missingODAInfo
    case downloadFailed(String)
    case decompressFailed(String)
    case librariesStillMissing

    var errorDescription: String? {
        switch self {
        case .badServerList: return "Không đọc được danh sách máy chủ anisette."
        case .missingODAInfo: return "Không tìm thấy cấu hình thư viện ODA (on-device anisette) trong phản hồi máy chủ."
        case .downloadFailed(let s): return "Tải gói thư viện ODA thất bại: \(s)"
        case .decompressFailed(let s): return "Giải nén gói thư viện ODA thất bại: \(s)"
        case .librariesStillMissing: return "Sau khi tải vẫn thiếu thư viện libstoreservicescore.so/libCoreADI.so."
        }
    }
}

/// Dạng rút gọn của JSON servers.json / oda.json — chỉ lấy các trường ta cần.
private struct ODAServerList: Decodable {
    let oda: ODAEntry?
}

/// "oda" có thể là một chuỗi đường dẫn tới file JSON khác, hoặc là một object chứa
/// thẳng URL/base64 + sha256 — nên decode thủ công cho cả hai dạng.
private enum ODAEntry: Decodable {
    case path(String)
    case info(ODAInfo)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .path(s)
        } else if let info = try? c.decode(ODAInfo.self) {
            self = .info(info)
        } else {
            throw DecodingError.typeMismatch(ODAEntry.self, .init(codingPath: decoder.codingPath, debugDescription: "oda phải là chuỗi đường dẫn hoặc object"))
        }
    }
}

private struct ODAInfo: Decodable {
    let url: String?
    let sha256: String?
    // Một số nguồn nhúng thẳng payload base64 thay vì URL tải.
    let l: String?

    var effectiveURLString: String? {
        if let url, url.hasPrefix("http") { return url }
        if let l, l.hasPrefix("http") { return l }
        return nil
    }
    var inlineBase64: String? {
        if let l, !l.hasPrefix("http") { return l }
        return nil
    }
}

/// Quản lý toàn bộ vòng đời anisette cho tính năng Developer login: tải thư viện ADI
/// (nếu chưa có), rồi cấp "anisette data" (các header X-Apple-I-MD*, X-Mme-Client-Info…)
/// mà GrandSlam/GSA yêu cầu trong mỗi request đăng nhập.
actor DevAnisette {
    static let shared = DevAnisette()

    private let baseDir: URL
    private var cachedClient: AnisetteClient?

    private init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDir = docs.appendingPathComponent("DevAnisette", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    private var libsDir: URL { baseDir.appendingPathComponent("libs", isDirectory: true) }
    private var provisioningDir: URL { baseDir.appendingPathComponent("provisioning", isDirectory: true) }

    /// true nếu 2 thư viện ADI đã có sẵn trên máy (không cần tải lại).
    func isReady() -> Bool {
        AnisetteClient.validateLibrariesExist(at: libsDir, requiredLibraries: DevAnisetteConstants.requiredLibraryNames)
    }

    /// Tải 2 thư viện ADI từ máy chủ ODA cộng đồng của SideStore (nếu chưa có sẵn trên máy).
    func ensureLibrariesDownloaded(progress: (@Sendable (String) -> Void)? = nil) async throws {
        if isReady() { return }

        try FileManager.default.createDirectory(at: libsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: provisioningDir, withIntermediateDirectories: true)

        progress?("Đang lấy danh sách máy chủ anisette…")
        let odaInfo = try await resolveODAInfo()

        progress?("Đang tải gói thư viện ADI…")
        let zipData = try await downloadZip(for: odaInfo)

        progress?("Đang giải nén…")
        let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try zipData.write(to: tmpZip)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        do {
            let archive = try Archive(url: tmpZip, accessMode: .read)
            for entry in archive {
                let fileName = (entry.path as NSString).lastPathComponent
                guard DevAnisetteConstants.requiredLibraryNames.contains(fileName) else { continue }
                let dest = libsDir.appendingPathComponent(fileName)
                _ = try archive.extract(entry, to: dest)
            }
        } catch {
            throw DevAnisetteError.decompressFailed(error.localizedDescription)
        }

        guard isReady() else { throw DevAnisetteError.librariesStillMissing }
        progress?("Đã sẵn sàng thư viện ADI.")
    }

    /// Lấy bộ header anisette cho một "identifier" (UUID định danh thiết bị ảo — tự
    /// sinh và lưu lại cố định cho app này, không liên quan UDID máy thật).
    func fetchHeaders() async throws -> [String: String] {
        try await ensureLibrariesDownloaded()
        let client = try obtainClient()
        let identifier = Self.persistentIdentifier()
        let (headers, _) = try await client.getAnisetteData(identifier: identifier, storage: .disk)
        return headers
    }

    private func obtainClient() throws -> AnisetteClient {
        if let cachedClient { return cachedClient }
        let dir = libsDir
        let client = try AnisetteClient(
            provisioningDir: provisioningDir,
            requiredLibraries: DevAnisetteConstants.requiredLibraryNames,
            libraryDirectoryResolver: { dir }
        )
        cachedClient = client
        return client
    }

    /// UUID cố định cho máy ảo anisette của app này — sinh một lần, lưu vào UserDefaults.
    private static func persistentIdentifier() -> UUID {
        let key = "DevAnisette.identifier"
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }

    private func resolveODAInfo() async throws -> ODAInfo {
        if let info = try? await fetchODAEntry(from: DevAnisetteConstants.serverListURL) {
            switch info {
            case .info(let i): return i
            case .path(let p):
                guard let url = URL(string: p, relativeTo: DevAnisetteConstants.serverListURL)?.absoluteURL else { break }
                if let direct = try? await fetchODAInfoDirect(from: url) { return direct }
            }
        }
        // rơi về thẳng oda.json mặc định
        return try await fetchODAInfoDirect(from: DevAnisetteConstants.fallbackODAMetadataURL)
    }

    private func fetchODAEntry(from url: URL) async throws -> ODAEntry {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DevAnisetteError.badServerList
        }
        let list = try JSONDecoder().decode(ODAServerList.self, from: data)
        guard let oda = list.oda else { throw DevAnisetteError.missingODAInfo }
        return oda
    }

    private func fetchODAInfoDirect(from url: URL) async throws -> ODAInfo {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DevAnisetteError.badServerList
        }
        return try JSONDecoder().decode(ODAInfo.self, from: data)
    }

    private func downloadZip(for info: ODAInfo) async throws -> Data {
        if let b64 = info.inlineBase64, let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            return decoded
        }
        guard let urlStr = info.effectiveURLString, let url = URL(string: urlStr) else {
            throw DevAnisetteError.missingODAInfo
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DevAnisetteError.downloadFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        // Có nguồn trả thẳng base64 dưới dạng text thay vì file zip nhị phân.
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
            return decoded
        }
        return data
    }
}
