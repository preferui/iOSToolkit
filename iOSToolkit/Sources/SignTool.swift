import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

// MARK: - Kho chứng chỉ (p12 + mobileprovision), port đơn giản từ Rsign

struct SignCert: Identifiable, Equatable {
    let id: String   // tên thư mục (uuid)
    var name: String
    var subject: String
    var password: String
    var p12URL: URL
    var provURL: URL
    var provInfo: [String: Any]?

    static func == (l: SignCert, r: SignCert) -> Bool { l.id == r.id }

    var teamName: String { (provInfo?["TeamName"] as? String) ?? "" }
    var expiration: Date? { provInfo?["ExpirationDate"] as? Date }
    var isExpired: Bool { if let e = expiration { return e.timeIntervalSinceNow < 0 }; return false }
    var deviceSummary: String {
        if (provInfo?["ProvisionsAllDevices"] as? Bool) == true { return "Doanh nghiệp" }
        if let devs = provInfo?["ProvisionedDevices"] as? [Any] { return "\(devs.count) thiết bị" }
        return "Phân phối"
    }
    var summaryText: String {
        let exp = expiration.map { SignStore.dateFormatter.string(from: $0) } ?? "?"
        var parts: [String] = []
        if !teamName.isEmpty { parts.append(teamName) }
        parts.append(deviceSummary)
        return "\(parts.joined(separator: " · ")) · \(isExpired ? "Đã hết hạn" : "Hết hạn") \(exp)"
    }
    var summaryColor: Color {
        if isExpired { return .red }
        if let e = expiration, e.timeIntervalSinceNow < 7 * 86400 { return .orange }
        return .green
    }
}

enum SignStoreError: LocalizedError {
    case p12Unreadable, wrongPassword, provUnreadable
    var errorDescription: String? {
        switch self {
        case .p12Unreadable: return "Không đọc được file .p12 (sai định dạng hoặc hỏng)."
        case .wrongPassword: return "Sai mật khẩu .p12."
        case .provUnreadable: return "File .mobileprovision không đọc được."
        }
    }
}

enum SignStore {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; return f
    }()

    static var root: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SignCerts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// mobileprovision là CMS ký nhị phân có nhúng 1 đoạn plist XML ở giữa — đọc thẳng đoạn đó.
    static func provInfo(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let start = data.range(of: Data("<?xml".utf8)) else { return nil }
        guard let endMarker = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plData = data.subdata(in: start.lowerBound..<endMarker.upperBound)
        return try? PropertyListSerialization.propertyList(from: plData, format: nil) as? [String: Any]
    }

    @discardableResult
    static func checkP12(_ url: URL, password: String) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw SignStoreError.p12Unreadable }
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if st == errSecAuthFailed { throw SignStoreError.wrongPassword }
        guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first else { throw SignStoreError.p12Unreadable }
        var subject = ""
        if let raw = first[kSecImportItemIdentity as String] {
            let identity = raw as! SecIdentity  // swiftlint:disable:this force_cast
            var certRef: SecCertificate?
            if SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let certRef {
                subject = (SecCertificateCopySubjectSummary(certRef) as String?) ?? ""
            }
        }
        return subject
    }

    static func list() -> [SignCert] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [SignCert] = []
        for d in dirs {
            let metaURL = d.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { continue }
            let p12 = d.appendingPathComponent("cert.p12")
            let prov = d.appendingPathComponent("prov.mobileprovision")
            guard FileManager.default.fileExists(atPath: p12.path), FileManager.default.fileExists(atPath: prov.path) else { continue }
            out.append(SignCert(id: d.lastPathComponent, name: meta["name"] ?? d.lastPathComponent, subject: meta["subject"] ?? "",
                                 password: meta["password"] ?? "", p12URL: p12, provURL: prov, provInfo: provInfo(prov)))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func hasAny() -> Bool {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty) == false
    }

    @discardableResult
    static func save(p12: URL, prov: URL, name: String, password: String) throws -> SignCert {
        let subject = try checkP12(p12, password: password)
        guard let pi = provInfo(prov) else { throw SignStoreError.provUnreadable }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: p12, to: dir.appendingPathComponent("cert.p12"))
        try FileManager.default.copyItem(at: prov, to: dir.appendingPathComponent("prov.mobileprovision"))
        let finalName = name.isEmpty ? ((pi["Name"] as? String) ?? "Chứng chỉ") : name
        let meta: [String: String] = ["name": finalName, "password": password, "subject": subject]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        return SignCert(id: dir.lastPathComponent, name: finalName, subject: subject, password: password,
                         p12URL: dir.appendingPathComponent("cert.p12"), provURL: dir.appendingPathComponent("prov.mobileprovision"), provInfo: pi)
    }

    static func delete(_ cert: SignCert) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(cert.id))
    }
}

// MARK: - Ký IPA (bọc công cụ zsign biên dịch sẵn trong app)

enum IPASigner {
    /// Bỏ mã màu ANSI (ví dụ "\u{1B}[31m") trong log của zsign — nếu để nguyên sẽ hiện
    /// thành chữ rác kiểu "[31m" trên màn hình vì app không phải terminal.
    private static func stripANSI(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2
                while j < chars.count, !chars[j].isLetter { j += 1 }
                i = j < chars.count ? j + 1 : j
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    static func sign(src: URL, cert: SignCert, log: @escaping (String) -> Void) throws -> URL {
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw NSError(domain: "IPASigner", code: -2, userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy tệp IPA nguồn nữa (có thể đã bị hệ thống dọn) — hãy chọn lại tệp rồi ký lại."])
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let out = work.appendingPathComponent("out.ipa")

        let prevCWD = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(work.path)
        defer { FileManager.default.changeCurrentDirectoryPath(prevCWD) }

        log("[chẩn đoán 1] " + ZSignProbeZip(src.path))
        let probeDir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        log("[chẩn đoán 2] " + ZSignProbeExtract(src.path, probeDir.path))
        log("[chẩn đoán 3] zsign dùng thư mục tạm tường minh: " + work.path)

        let args = ["-d", "-t", work.path, "-k", cert.p12URL.path, "-p", cert.password, "-m", cert.provURL.path, "-o", out.path, "-z", "3", src.path]
        let rc = ZSignRun(args) { line in log(stripANSI(line)) }
        guard rc == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw NSError(domain: "IPASigner", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "zsign báo lỗi (mã \(rc)). Xem nhật ký bên dưới — thường do p12/mobileprovision không khớp nhau, hoặc chứng chỉ đã hết hạn.",
            ])
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Signed-\(UUID().uuidString).ipa")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: out, to: dest)
        return dest
    }
}

// MARK: - Thêm chứng chỉ

struct AddSignCertView: View {
    var onSaved: (SignCert) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var p12URL: URL?
    @State private var provURL: URL?
    @State private var provSummary: String?
    @State private var scoped: [URL] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ví dụ: Chứng chỉ của tôi", text: $name)
                } header: { Text("Tên (tuỳ chọn)") }

                Section {
                    Button { pick(.p12) } label: { Label(p12URL?.lastPathComponent ?? "Chọn tệp .p12", systemImage: "doc") }
                    Button { pick(.prov) } label: { Label(provURL?.lastPathComponent ?? "Chọn tệp .mobileprovision", systemImage: "doc.badge.gearshape") }
                    if let provSummary {
                        Text(provSummary).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Tệp chứng chỉ") }

                Section {
                    SecureField("Mật khẩu .p12 (để trống nếu không có)", text: $password)
                } footer: {
                    Text("Chứng chỉ được lưu riêng trong máy của bạn, không gửi đi đâu.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button {
                        save()
                    } label: { HStack { Text(busy ? "Đang lưu…" : "Lưu chứng chỉ"); if busy { Spacer(); ProgressView() } } }
                    .disabled(p12URL == nil || provURL == nil || busy)
                }
            }
            .navigationTitle("Thêm chứng chỉ")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } } }
        }
        .onDisappear { for u in scoped { u.stopAccessingSecurityScopedResource() } }
    }

    private enum Pick { case p12, prov }
    private static let p12Type = UTType(filenameExtension: "p12") ?? .data
    private static let provType = UTType(filenameExtension: "mobileprovision") ?? .data
    private func pick(_ which: Pick) {
        let types = which == .p12 ? [Self.p12Type] : [Self.provType]
        DocPicker.present(types: types, asCopy: true) { urls in
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            scoped.append(url)
            switch which {
            case .p12: p12URL = url
            case .prov:
                provURL = url
                if let pi = SignStore.provInfo(url) {
                    let team = pi["TeamName"] as? String ?? ""
                    let nm = pi["Name"] as? String ?? ""
                    provSummary = [nm, team].filter { !$0.isEmpty }.joined(separator: " · ")
                    if name.isEmpty { name = nm }
                } else {
                    provSummary = "⚠️ Không đọc được file .mobileprovision"
                }
            }
        }
    }

    private func save() {
        guard let p12URL, let provURL else { return }
        busy = true; error = nil
        Task {
            do {
                let cert = try await Task.detached { try SignStore.save(p12: p12URL, prov: provURL, name: name, password: password) }.value
                onSaved(cert)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Màn hình ký IPA

struct SignToolView: View {
    var initialIPA: URL?

    @State private var srcURL: URL?
    @State private var certs: [SignCert] = []
    @State private var selected: SignCert?
    @State private var showAddCert = false
    @State private var showIPASources = false
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var logText = ""
    @State private var showLog = false
    @State private var signedURL: URL?

    var body: some View {
        Form {
            Section {
                Button { pickIPA() } label: {
                    sourceRow(icon: "shippingbox", title: srcURL?.lastPathComponent ?? "Chọn tệp .ipa cần ký…")
                }
                Button { showIPASources = true } label: {
                    sourceRow(icon: "square.stack.3d.up", title: "Chọn IPA từ nguồn")
                }
            } header: { Text("Tệp IPA") } footer: {
                Text("Nên dùng IPA chưa ký (ví dụ bản xuất từ “Nhân bản / Edit IPA”). zsign sẽ ký đè, không cần gỡ chữ ký cũ trước.")
            }

            Section {
                if certs.isEmpty {
                    Text("Chưa có chứng chỉ nào.").foregroundStyle(.secondary)
                } else {
                    ForEach(certs) { c in
                        Button {
                            selected = c
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(.primary)
                                    Text(c.summaryText).font(.caption).foregroundStyle(c.summaryColor)
                                }
                                Spacer()
                                if selected?.id == c.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                SignStore.delete(c)
                                if selected?.id == c.id { selected = nil }
                                certs = SignStore.list()
                            } label: { Label("Xoá", systemImage: "trash") }
                        }
                    }
                }
                Button { showAddCert = true } label: { Label("Thêm chứng chỉ…", systemImage: "plus.circle") }
            } header: { Text("Chứng chỉ ký") }

            Section {
                Button {
                    run()
                } label: { HStack { Image(systemName: "signature"); Text(busy ? "Đang ký…" : "Ký IPA"); if busy { Spacer(); ProgressView() } } }
                .disabled(srcURL == nil || selected == nil || busy)
            }

            if !logText.isEmpty {
                Section {
                    Button { showLog = true } label: { Label("Xem nhật ký", systemImage: "doc.text.magnifyingglass") }
                }
            }

            if let signedURL {
                Section {
                    Button {
                        installSignedIPA(signedURL)
                    } label: {
                        Label("Cài trực tiếp lên iPhone", systemImage: "arrow.down.app.fill")
                    }
                } footer: {
                    Text("Cài trực tiếp sẽ mở trình cài đặt của iOS. Chứng chỉ và provisioning profile vẫn phải hợp lệ cho thiết bị.")
                }
            }
        }
        .navigationTitle("Ký IPA")
        .overlay(alignment: .top) { banner }
        .animation(.easeInOut(duration: 0.2), value: message)
        .sheet(isPresented: $showAddCert) {
            AddSignCertView { cert in
                certs = SignStore.list()
                selected = cert
            }
        }
        .sheet(isPresented: $showIPASources) {
            NavigationStack {
                IPASourcesView { downloadedURL in
                    useIPA(downloadedURL)
                    showIPASources = false
                }
            }
        }
        .alert("Nhật ký", isPresented: $showLog) {
            Button("Đóng", role: .cancel) {}
        } message: { Text(trimmedLog) }
        .onAppear {
            certs = SignStore.list()
            if selected == nil { selected = certs.first }
            if srcURL == nil, let initialIPA { useIPA(initialIPA) }
        }
        .onDisappear { if let srcURL { try? FileManager.default.removeItem(at: srcURL) } }
    }

    /// Hàng chọn nguồn IPA (chọn tệp / chọn từ nguồn) với icon cùng khung rộng và khoảng cách
    /// giống nhau, để hai nút không bị lệch chữ do các icon SF Symbols có bề ngang khác nhau.
    @ViewBuilder
    private func sourceRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(.tint)
            Text(title).lineLimit(1)
        }
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

    /// Sao chép ngay file nguồn vào một chỗ ổn định của app (tmp của riêng app) thay vì giữ
    /// nguyên URL do document picker trả về: file trong thư mục "-Inbox" của picker có thể bị
    /// iOS tự dọn sau một lúc, gây lỗi "Invalid path"/"Unzip failed" nếu ký trễ hoặc ký lại.
    private func stabilize(_ url: URL) -> URL? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("SignSrc-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dst)
            return dst
        } catch {
            Diag.log("sign: lỗi sao chép nguồn \(error)")
            return nil
        }
    }

    /// Lỗi thật thường xảy ra ngay đầu log (ngay sau bước Unzip); log debug (-d) lại rất dài,
    /// nên giữ phần đầu + phần cuối, bớt đoạn giữa, thay vì chỉ giữ phần cuối như trước.
    private var trimmedLog: String {
        guard logText.count > 3000 else { return logText }
        let head = String(logText.prefix(1800))
        let tail = String(logText.suffix(1200))
        return head + "\n…(lược bớt đoạn giữa)…\n" + tail
    }

    private func useIPA(_ url: URL) {
        guard let stable = stabilize(url) else {
            isError = true
            message = "Không sao chép được tệp đã chọn (có thể bị hệ thống dọn file tạm trước khi đọc)."
            return
        }
        if let old = srcURL { try? FileManager.default.removeItem(at: old) }
        srcURL = stable
        signedURL = nil
    }

    private func pickIPA() {
        DocPicker.present(types: [.zip, .data, .item], asCopy: true) { urls in
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            guard ext == "ipa" || ext == "zip" else { isError = true; message = "Tệp “\(url.lastPathComponent)” không phải .ipa."; return }
            message = nil
            useIPA(url)
        }
    }

    private func installSignedIPA(_ url: URL) {
        guard let archive = Archive(url: url, accessMode: .read) else {
            isError = true
            message = "Không đọc được IPA đã ký để lấy thông tin ứng dụng."
            return
        }
        var appInfo: [String: Any]?
        for entry in archive {
            let parts = entry.path.split(separator: "/")
            guard parts.count == 3,
                  parts[0] == "Payload",
                  parts[1].hasSuffix(".app"),
                  parts[2] == "Info.plist" else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
                appInfo = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            } catch {
                Diag.log("install: không đọc được Info.plist: \(error)")
            }
            break
        }
        guard let info = appInfo,
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            isError = true
            message = "Không tìm thấy CFBundleIdentifier trong IPA đã ký."
            return
        }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? (info["CFBundleExecutable"] as? String)
            ?? bundleID
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "1.0"
        message = "Đang mở trình cài đặt iOS…"
        isError = false
        LocalInstaller.shared.install(ipa: url, bundleID: bundleID, name: name, version: version) { error in
            DispatchQueue.main.async {
                if let error {
                    isError = true
                    message = error
                } else {
                    isError = false
                    message = "Đã gửi yêu cầu cài đặt đến iOS. Hãy xác nhận trong hộp thoại hệ thống; nếu không xuất hiện, hãy kiểm tra chứng chỉ và provisioning profile."
                }
            }
        }
    }

    private func run() {
        guard let srcURL, let selected else { return }
        busy = true; message = nil; signedURL = nil; logText = ""
        Diag.log("sign: ký \(srcURL.lastPathComponent) bằng chứng chỉ \(selected.name)")
        Task {
            do {
                let url = try await Task.detached {
                    try IPASigner.sign(src: srcURL, cert: selected) { line in
                        Task { @MainActor in logText += line + "\n" }
                    }
                }.value
                signedURL = url
                isError = false
                message = "Ký IPA thành công. Nhấn “Cài trực tiếp lên iPhone” để tiếp tục cài đặt."
                Diag.log("sign: xong -> \(url.lastPathComponent)")
            } catch {
                isError = true
                message = error.localizedDescription
                Diag.log("sign: lỗi \(error)")
            }
            busy = false
        }
    }
}
