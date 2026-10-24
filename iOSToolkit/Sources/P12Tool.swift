import OpenSSL
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

// MARK: - Lõi đổi mật khẩu p12

enum P12Error: LocalizedError {
    case wrongPassword, unreadable, buildFailed, verifyFailed, unsupportedKey, noP12, badZip, failed(String, Error)
    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Mật khẩu cũ không đúng."
        case .unreadable: return "Không đọc được tệp p12 (định dạng lạ hoặc bị hỏng)."
        case .buildFailed: return "Không tạo được p12 mới."
        case .verifyFailed: return "p12 mới tạo xong nhưng iOS không mở được bằng mật khẩu mới nên đã huỷ, tệp gốc chưa bị đổi."
        case .unsupportedKey: return "Loại khoá trong p12 này chưa được hỗ trợ (chỉ hỗ trợ khoá RSA)."
        case .noP12: return "Không thấy tệp .p12 hoặc .pfx trong gói zip."
        case .badZip: return "Không mở được gói zip (có thể bị hỏng hoặc có đặt mật khẩu)."
        case let .failed(name, e): return "\(name): \(e.localizedDescription)"
        }
    }
}

enum P12Core {
    private typealias Parts = (key: OpaquePointer, cert: OpaquePointer, ca: OpaquePointer?)

    static func change(_ p12: Data, old: String, new: String) throws -> Data {
        if let parts = parseOpenSSL(p12, pass: old) {
            defer { free(parts) }
            guard let out = build(parts, pass: new) else { throw P12Error.buildFailed }
            try verify(out, pass: new)
            return out
        }
        // OpenSSL không đọc được (thường do thuật toán cũ như RC2-40): nhờ iOS đọc rồi dựng lại.
        let parts = try parseViaSecurity(p12, pass: old)
        defer { free(parts) }
        guard let out = build(parts, pass: new) else { throw P12Error.buildFailed }
        try verify(out, pass: new)
        return out
    }

    private static func free(_ p: Parts) {
        EVP_PKEY_free(p.key)
        X509_free(p.cert)
        if let ca = p.ca { OPENSSL_sk_pop_free(ca) { ptr in if let ptr { X509_free(OpaquePointer(ptr)) } } }
    }

    private static func parseOpenSSL(_ data: Data, pass: String) -> Parts? {
        _ = OSSL_PROVIDER_load(nil, "legacy")   // nếu có thì đọc được cả thuật toán cũ; không có thì bỏ qua
        _ = OSSL_PROVIDER_load(nil, "default")
        let bytes = [UInt8](data)
        var p12: OpaquePointer?
        bytes.withUnsafeBufferPointer { b in
            var cur: UnsafePointer<UInt8>? = b.baseAddress
            p12 = d2i_PKCS12(nil, &cur, bytes.count)
        }
        guard let p12 else { ERR_clear_error(); return nil }
        defer { PKCS12_free(p12) }
        var key: OpaquePointer?
        var cert: OpaquePointer?
        var ca: OpaquePointer?
        guard PKCS12_parse(p12, pass, &key, &cert, &ca) == 1, let key, let cert else {
            ERR_clear_error()
            if let k = key { EVP_PKEY_free(k) }
            if let c = cert { X509_free(c) }
            return nil
        }
        return (key, cert, ca)
    }

    private static func parseViaSecurity(_ data: Data, pass: String) throws -> Parts {
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: pass] as CFDictionary, &items)
        if st == errSecAuthFailed { throw P12Error.wrongPassword }
        guard st == errSecSuccess, let first = (items as? [[String: Any]])?.first, let raw = first[kSecImportItemIdentity as String] else { throw P12Error.unreadable }
        // swiftlint:disable:next force_cast
        let identity = raw as! SecIdentity
        var keyRef: SecKey?
        var certRef: SecCertificate?
        SecIdentityCopyPrivateKey(identity, &keyRef)
        SecIdentityCopyCertificate(identity, &certRef)
        guard let keyRef, let certRef else { throw P12Error.unreadable }
        guard let attrs = SecKeyCopyAttributes(keyRef) as? [String: Any], (attrs[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeRSA as String) else { throw P12Error.unsupportedKey }
        var err: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(keyRef, &err) as Data? else { throw P12Error.unsupportedKey }
        let keyBytes = [UInt8](keyData)
        var pk: OpaquePointer?
        keyBytes.withUnsafeBufferPointer { b in
            var cur: UnsafePointer<UInt8>? = b.baseAddress
            pk = d2i_AutoPrivateKey(nil, &cur, keyBytes.count)
        }
        func x509(_ c: SecCertificate) -> OpaquePointer? {
            let der = [UInt8](SecCertificateCopyData(c) as Data)
            var out: OpaquePointer?
            der.withUnsafeBufferPointer { b in
                var cur: UnsafePointer<UInt8>? = b.baseAddress
                out = d2i_X509(nil, &cur, der.count)
            }
            return out
        }
        guard let pk, let leaf = x509(certRef) else { ERR_clear_error(); throw P12Error.unreadable }
        var ca: OpaquePointer?
        if let chain = first[kSecImportItemCertChain as String] as? [SecCertificate] {
            let leafDER = SecCertificateCopyData(certRef) as Data
            for c in chain where (SecCertificateCopyData(c) as Data) != leafDER {
                if let xc = x509(c) {
                    if ca == nil { ca = OPENSSL_sk_new_null() }
                    _ = OPENSSL_sk_push(ca, UnsafeMutableRawPointer(xc))
                }
            }
        }
        return (pk, leaf, ca)
    }

    private static func build(_ p: Parts, pass: String) -> Data? {
        guard let p12 = PKCS12_create(pass, nil, p.key, p.cert, p.ca, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, -1, 0) else { ERR_clear_error(); return nil }
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

    /// Kiểm tra lại bằng chính bộ đọc của iOS với mật khẩu mới.
    private static func verify(_ data: Data, pass: String) throws {
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: pass] as CFDictionary, &items)
        guard st == errSecSuccess, let first = (items as? [[String: Any]])?.first, first[kSecImportItemIdentity as String] != nil else { throw P12Error.verifyFailed }
    }
}

// MARK: - Xử lý gói zip

struct P12ZipResult {
    var data: Data
    var names: [String]
    var wroteBack: Bool
    var writeError: String?
    var backup: URL?
}

enum P12Zip {
    static func process(src: URL, old: String, new: String, writeBack: Bool) throws -> P12ZipResult {
        let original = try Data(contentsOf: src)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("p12-\(UUID().uuidString).zip")
        try original.write(to: work)
        defer { try? FileManager.default.removeItem(at: work) }

        guard let archive = try? Archive(url: work, accessMode: .update) else { throw P12Error.badZip }
        var targets: [String] = []
        for e in archive where e.type == .file {
            let low = e.path.lowercased()
            let leaf = (e.path as NSString).lastPathComponent
            if (low.hasSuffix(".p12") || low.hasSuffix(".pfx")) && !low.hasPrefix("__macosx/") && !leaf.hasPrefix("._") { targets.append(e.path) }
        }
        guard !targets.isEmpty else { throw P12Error.noP12 }

        var results: [(String, Data)] = []
        for path in targets {
            guard let entry = archive[path] else { continue }
            var data = Data()
            do { _ = try archive.extract(entry) { data.append($0) } } catch { throw P12Error.badZip }
            do { results.append((path, try P12Core.change(data, old: old, new: new))) }
            catch { throw targets.count > 1 ? P12Error.failed((path as NSString).lastPathComponent, error) : error }
        }
        for (path, out) in results {
            if let cur = archive[path] { try archive.remove(cur) }
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(out.count), compressionMethod: .deflate) { pos, size in
                out.subdata(in: Int(pos) ..< Int(pos) + size)
            }
        }
        let newZip = try Data(contentsOf: work)
        // Sao lưu bản gốc trong thư mục của app (xem ở app Tệp) rồi ghi đè trực tiếp.
        var backup: URL?
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("P12Backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = dir.appendingPathComponent(src.lastPathComponent)
        if (try? original.write(to: b)) != nil { backup = b }
        var wrote = false
        var werr: String?
        if !writeBack { return P12ZipResult(data: newZip, names: results.map { ($0.0 as NSString).lastPathComponent }, wroteBack: false, writeError: nil, backup: backup) }
        do {
            try newZip.write(to: src)
            wrote = (try? Data(contentsOf: src))?.count == newZip.count
            if !wrote { werr = "ghi xong nhưng kiểm tra lại không khớp" }
        } catch { werr = error.localizedDescription }
        return P12ZipResult(data: newZip, names: results.map { ($0.0 as NSString).lastPathComponent }, wroteBack: wrote, writeError: werr, backup: backup)
    }
}

/// Hộp chọn/lưu tệp dựng thẳng bằng UIKit (fileImporter của SwiftUI không trả kết quả ổn định trong Form).
final class DocPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: DocPicker?
    private var onPick: (([URL]) -> Void)?

    static func present(types: [UTType], asCopy: Bool, onPick: @escaping ([URL]) -> Void) {
        let c = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        show(c, onPick)
    }

    static func presentExport(_ file: URL, onPick: @escaping ([URL]) -> Void) {
        let c = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        show(c, onPick)
    }

    private static func show(_ c: UIDocumentPickerViewController, _ onPick: @escaping ([URL]) -> Void) {
        let d = DocPicker()
        d.onPick = onPick
        current = d
        c.delegate = d
        c.allowsMultipleSelection = false
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        top.present(c, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Diag.log("hộp chọn tệp: nhận \(urls.map(\.lastPathComponent))")
        onPick?(urls); DocPicker.current = nil
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        Diag.log("hộp chọn tệp: huỷ")
        DocPicker.current = nil
    }
}

// MARK: - Giao diện

struct P12ToolView: View {
    @State private var zipURL: URL?
    @State private var scoped: URL?
    @State private var oldPass = ""
    @State private var newPass = ""
    @State private var show = false
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var exportURL: URL?
    @FocusState private var focus: Bool

    private var baseName: String { (zipURL?.deletingPathExtension().lastPathComponent) ?? "chung-chi" }

    var body: some View {
        Form {
            Section {
                Button { pickZip() } label: {
                    HStack {
                        Image(systemName: "doc.zipper")
                        Text(zipURL?.lastPathComponent ?? "Chọn gói zip chứng chỉ…").lineLimit(1)
                    }
                }
            } header: { Text("Gói chứng chỉ") } footer: {
                Text("Gói zip chứa tệp .p12 (và thường cả .mobileprovision). Sau khi đổi, app mở hộp lưu tệp với đúng tên cũ để bạn bấm “Thay thế”.")
            }

            Section {
                field("Mật khẩu cũ", $oldPass)
                field("Mật khẩu mới", $newPass)
                Toggle("Hiện mật khẩu", isOn: $show)
            } header: { Text("Mật khẩu") }

            Section {
                Button {
                    focus = false
                    run()
                } label: { HStack { Image(systemName: "key.fill"); Text(busy ? "Đang đổi…" : "Đổi mật khẩu"); if busy { Spacer(); ProgressView() } } }
                .disabled(zipURL == nil || oldPass.isEmpty || newPass.isEmpty || busy)
            } footer: {
                Text("Bản gốc được sao lưu trong thư mục “P12Backup” của app. Sau khi đổi, app mở hộp lưu tệp với đúng tên cũ: chọn thư mục chứa tệp gốc rồi bấm “Thay thế”.")
            }

            if let url = exportURL {
                Section {
                    Button { saveExport(url) } label: { Label("Lưu bản zip mới…", systemImage: "square.and.arrow.down") }
                    ShareLink(item: url) { Label("Chia sẻ bản zip mới", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Đổi mật khẩu P12")
        .scrollDismissesKeyboard(.immediately)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Xong") { focus = false } } }
        .overlay(alignment: .top) { banner }
        .animation(.easeInOut(duration: 0.2), value: message)
        .onDisappear { scoped?.stopAccessingSecurityScopedResource(); scoped = nil }
    }

    @ViewBuilder private func field(_ title: String, _ binding: Binding<String>) -> some View {
        Group {
            if show { TextField(title, text: binding) } else { SecureField(title, text: binding) }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus)
    }

    @ViewBuilder private var banner: some View {
        if let message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundColor(isError ? .red : .green)
                Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                Button { self.message = nil } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 12).padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func pickZip() {
        focus = false
        DocPicker.present(types: [.zip, .data, .item], asCopy: true) { urls in
            guard let url = urls.first else { return }
            guard url.pathExtension.lowercased() == "zip" else { isError = true; message = "Tệp “\(url.lastPathComponent)” không phải .zip."; return }
            scoped?.stopAccessingSecurityScopedResource()
            let ok = url.startAccessingSecurityScopedResource()
            Diag.log("p12: chọn \(url.lastPathComponent), quyền truy cập=\(ok)")
            scoped = url; zipURL = url; exportURL = nil; message = nil
        }
    }

    private func saveExport(_ url: URL) {
        DocPicker.presentExport(url) { _ in isError = false; message = "Đã lưu bản zip mới." }
    }

    private func run() {
        guard let src = zipURL else { return }
        busy = true; message = nil; exportURL = nil
        let o = oldPass, n = newPass
        Diag.log("p12: đổi mật khẩu cho \(src.lastPathComponent)")
        Task {
            do {
                let r = try await Task.detached { try P12Zip.process(src: src, old: o, new: n, writeBack: false) }.value
                let names = r.names.joined(separator: ", ")
                if r.wroteBack {
                    isError = false
                    message = "Đã đổi mật khẩu \(names) và ghi đè trực tiếp vào “\(src.lastPathComponent)”." + (r.backup != nil ? " Bản gốc được sao lưu trong thư mục P12Backup của app." : "")
                    oldPass = ""; newPass = ""
                } else {
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent(src.lastPathComponent)
                    try? FileManager.default.removeItem(at: out)
                    try r.data.write(to: out)
                    exportURL = out
                    isError = false
                    message = "Đã đổi mật khẩu \(names). Hộp lưu tệp sẽ mở với đúng tên cũ: chọn thư mục chứa tệp gốc rồi bấm “Thay thế”."
                    saveExport(out)
                }
                Diag.log("p12: xong, ghi đè=\(r.wroteBack) \(r.writeError ?? "")")
            } catch {
                isError = true
                message = error.localizedDescription
                Diag.log("p12: lỗi \(error)")
            }
            busy = false
        }
    }
}
