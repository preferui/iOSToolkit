import Foundation
import Network
import OpenSSL
import Security

/// Danh tính TLS cho máy chủ cục bộ: dùng chứng chỉ công khai của backloop.dev (local.backloop.dev → 127.0.0.1),
/// nên iOS tin cậy sẵn và chấp nhận itms-services qua HTTPS.
enum LocalTLS {
    static let host = "local.backloop.dev"

    private static func derBlocks(_ pem: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for part in pem.components(separatedBy: "-----BEGIN ").dropFirst() {
            guard let headEnd = part.range(of: "-----\n") ?? part.range(of: "-----\r\n") ?? part.range(of: "-----") else { continue }
            let rest = part[headEnd.upperBound...]
            guard let end = rest.range(of: "-----END") else { continue }
            let b64 = rest[..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            if let d = Data(base64Encoded: b64) { out.append([UInt8](d)) }
        }
        return out
    }

    static func makeP12(cert: String, ca: String, key: String) -> Data? {
        guard let certDER = derBlocks(cert).first, let keyDER = derBlocks(key).first else { return nil }
        var x: OpaquePointer?
        var pk: OpaquePointer?
        certDER.withUnsafeBufferPointer { b in
            var cur: UnsafePointer<UInt8>? = b.baseAddress
            x = d2i_X509(nil, &cur, certDER.count)
        }
        keyDER.withUnsafeBufferPointer { b in
            var cur: UnsafePointer<UInt8>? = b.baseAddress
            pk = d2i_AutoPrivateKey(nil, &cur, keyDER.count)
        }
        guard let x, let pk else { return nil }
        defer { X509_free(x); EVP_PKEY_free(pk) }
        let stack = OPENSSL_sk_new_null()
        var chain: [OpaquePointer] = []
        for der in derBlocks(ca) {
            der.withUnsafeBufferPointer { b in
                var cur: UnsafePointer<UInt8>? = b.baseAddress
                if let c = d2i_X509(nil, &cur, der.count) { chain.append(c); _ = OPENSSL_sk_push(stack, UnsafeMutableRawPointer(c)) }
            }
        }
        defer { for c in chain { X509_free(c) }; OPENSSL_sk_free(stack) }
        let pass = "rs"
        guard let p12 = PKCS12_create(pass, pass, pk, x, stack, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, -1, 0) else { return nil }
        defer { PKCS12_free(p12) }
        _ = PKCS12_set_mac(p12, pass, -1, nil, 0, 2048, EVP_sha1())   // iOS chỉ hiểu MAC SHA1
        let len = Int(i2d_PKCS12(p12, nil))
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        let ok: Bool = buf.withUnsafeMutableBufferPointer { b in
            var cur: UnsafeMutablePointer<UInt8>? = b.baseAddress
            return i2d_PKCS12(p12, &cur) == len
        }
        return ok ? Data(buf) : nil
    }

    static func identity(completion: @escaping (sec_identity_t?, String?) -> Void) {
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iOSToolkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cache = cacheDir.appendingPathComponent("pack.json")
        var req = URLRequest(url: URL(string: "https://backloop.dev/pack.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            var d = data
            if d == nil || (resp as? HTTPURLResponse)?.statusCode != 200 { d = try? Data(contentsOf: cache) } else { try? d?.write(to: cache) }
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                completion(nil, "Không tải được chứng chỉ máy chủ cục bộ (cần mạng lần đầu)."); return
            }
            let cert = j["cert"] as? String ?? "", ca = j["ca"] as? String ?? ""
            let key = (j["key1"] as? String ?? "") + (j["key2"] as? String ?? "")
            guard let p12 = makeP12(cert: cert, ca: ca, key: key) else { completion(nil, "Không tạo được danh tính TLS từ chứng chỉ cục bộ."); return }
            var items: CFArray?
            let st = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: "rs"] as CFDictionary, &items)
            guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first, let raw = first[kSecImportItemIdentity as String] else {
                completion(nil, "Nhập danh tính TLS lỗi (\(st))."); return
            }
            // swiftlint:disable:next force_cast
            let ident = raw as! SecIdentity
            completion(sec_identity_create(ident), nil)
        }.resume()
    }
}
