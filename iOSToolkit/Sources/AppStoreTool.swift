import ApplePackage
import SwiftUI

@MainActor
final class DownloadJob: ObservableObject {
    @Published var running = false
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var finished: URL?

    static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("IPAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func run(email: String, appID: Int64, version: String?) async {
        let store = AccountStore.shared
        guard var acc = store.account(email) else { error = "Chưa chọn tài khoản."; return }
        running = true; error = nil; finished = nil; progress = 0
        defer { running = false }
        do {
            Diag.log("tải: id=\(appID) version=\(version ?? "-")")
            status = "Đang hỏi Apple…"
            let pkg: StorePackage
            do {
                pkg = try await StoreClient.package(account: &acc, appID: appID, version: version)
            } catch StoreError.rejected(let code, _) where code == "2034" || code == "2042" {
                status = "Phiên đăng nhập hết hạn, đang đăng nhập lại…"
                acc = try await ApplePackage.Authenticator.authenticate(email: acc.email, password: acc.password, code: "", cookies: acc.cookie)
                pkg = try await StoreClient.package(account: &acc, appID: appID, version: version)
            }
            store.save(acc)
            guard let url = URL(string: pkg.url) else { throw StoreError.invalidPackage }
            status = "Đang tải \(pkg.name.isEmpty ? String(appID) : pkg.name) \(pkg.version)…"
            let tmp = try await FileDownloader().download(url) { [weak self] p in Task { @MainActor in self?.progress = p } }
            status = "Đang gắn chữ ký của Apple vào IPA…"
            try await SignatureInjector.inject(sinfs: pkg.sinfs, iTunesMetadata: pkg.iTunesMetadata, into: tmp.path)
            let base = (pkg.bundleID.isEmpty ? String(appID) : pkg.bundleID) + "_" + pkg.version
            let safe = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            let dest = Self.folder.appendingPathComponent(safe + ".ipa")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            let meta = ["name": pkg.name.isEmpty ? safe : pkg.name, "bundle": pkg.bundleID, "version": pkg.version]
            try? JSONSerialization.data(withJSONObject: meta).write(to: dest.appendingPathExtension("json"))
            let iconURL = dest.appendingPathExtension("png")
            var iconData = await Task.detached { IPAIcon.extract(from: dest) }.value
            if iconData == nil { iconData = await IPAIcon.fromStore(appID: appID, country: Configuration.countryCode(for: acc.store)) }
            if let iconData { try? iconData.write(to: iconURL) }
            progress = 1; status = "Xong: \(dest.lastPathComponent)"; finished = dest
        } catch {
            Diag.log("tải: lỗi \(error)")
            self.error = error.localizedDescription
            status = ""
        }
    }
}

struct AppStoreToolView: View {
    @ObservedObject var store = AccountStore.shared
    @StateObject private var job = DownloadJob()
    @State private var email = ""
    @State private var idText = ""
    @State private var versionText = ""
    @State private var versions: [String] = []
    @State private var showVersions = false
    @State private var listing = false
    @State private var claiming = false
    @State private var files: [URL] = []

    private var appID: Int64? {
        let t = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int64(t) { return n }
        if let r = t.range(of: #"id(\d+)"#, options: .regularExpression) { return Int64(t[r].dropFirst(2)) }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if store.accounts.isEmpty {
                    NavigationLink { AddAccountView() } label: { Label("Thêm Apple ID để bắt đầu", systemImage: "person.crop.circle.badge.plus") }
                } else {
                    Picker("Tài khoản", selection: $email) {
                        ForEach(store.accounts, id: \.email) { Text($0.email).tag($0.email) }
                    }
                    NavigationLink { AccountsView() } label: { Text("Quản lý tài khoản") }
                }
            } header: { Text("Tài khoản") }

            Section {
                TextField("ID app hoặc link App Store", text: $idText).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("ID phiên bản (tuỳ chọn)", text: $versionText).keyboardType(.numberPad)
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); Task { await listVersions() }
                } label: { HStack { Text("Liệt kê phiên bản"); if listing { Spacer(); ProgressView() } } }
                .disabled(email.isEmpty || appID == nil || listing || job.running)
                Button {
                    guard let id = appID else { return }
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); Task { await claim(id) }
                } label: { HStack { Text("Nhận app vào tài khoản (miễn phí)"); if claiming { Spacer(); ProgressView() } } }
                .disabled(email.isEmpty || appID == nil || claiming || job.running)
            } header: { Text("Ứng dụng") } footer: {
                Text("ID là dãy số trong link App Store (apps.apple.com/…/id123456789). “Liệt kê phiên bản” chỉ dùng được với app mà Apple ID đã từng tải/nhận. Để trống ID phiên bản để tải bản mới nhất. App đã gỡ thường cần ID phiên bản cụ thể.")
            }

            Section {
                Button {
                    guard let id = appID else { return }
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); Task { await job.run(email: email, appID: id, version: versionText.trimmingCharacters(in: .whitespaces)); refresh() }
                } label: { HStack { Image(systemName: "arrow.down.circle.fill"); Text(job.running ? "Đang tải…" : "Tải IPA") } }
                .disabled(email.isEmpty || appID == nil || job.running)
                if job.running { ProgressView(value: job.progress) }
            }

            Section {
                if files.isEmpty { Text("Chưa có file nào.").foregroundColor(.secondary) }
                ForEach(files, id: \.self) { f in
                    let m = meta(f)
                    HStack(spacing: 12) {
                        icon(f)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text("v\(m.version) · \(size(f))").font(.caption).foregroundColor(.secondary)
                            if !m.bundle.isEmpty { Text(m.bundle).font(.caption2).foregroundColor(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Button { install(f) } label: { Text("Cài").font(.system(size: 14, weight: .bold)) }.buttonStyle(.borderedProminent).controlSize(.small)
                        ShareLink(item: f) { Image(systemName: "square.and.arrow.up") }.padding(.leading, 6)
                    }
                }
                .onDelete { idx in idx.forEach { try? FileManager.default.removeItem(at: files[$0]); try? FileManager.default.removeItem(at: files[$0].appendingPathExtension("json")); try? FileManager.default.removeItem(at: files[$0].appendingPathExtension("png")) }; refresh() }
            } header: { Text("File đã tải") } footer: {
                Text("Bấm “Cài” để cài thẳng lên máy này, giữ nguyên chữ ký của Apple (không cần chứng chỉ). Cần mở mạng lần đầu để iOS lấy trang cài đặt. File nằm trong thư mục “IPAs” (xem ở app Tệp).")
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Xong") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } }
        .overlay(alignment: .top) { banner }
        .animation(.easeInOut(duration: 0.2), value: job.status)
        .animation(.easeInOut(duration: 0.2), value: job.error)
        .navigationTitle("Tải IPA")
        .onAppear { if email.isEmpty || store.account(email) == nil { email = store.accounts.first?.email ?? "" }; refresh() }
        .sheet(isPresented: $showVersions) {
            NavigationStack {
                List(versions, id: \.self) { v in
                    Button(v) { versionText = v; showVersions = false }
                }
                .navigationTitle("Phiên bản (mới → cũ)")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { showVersions = false } } }
            }
        }
    }

    @ViewBuilder private var banner: some View {
        let err = job.error
        let msg = err ?? (job.status.isEmpty ? nil : job.status)
        if let msg {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: err != nil ? "exclamationmark.triangle.fill" : "info.circle.fill").foregroundColor(err != nil ? .red : .accentColor)
                Text(msg).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if !job.running {
                    Button { job.error = nil; job.status = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 12).padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Thêm app miễn phí vào tài khoản (như bấm “Nhận” trên App Store). Chỉ được khi app còn bán ở vùng của tài khoản.
    private func claim(_ id: Int64) async {
        guard var acc = store.account(email) else { return }
        claiming = true; job.error = nil; job.status = ""
        defer { claiming = false }
        let sw = Software(id: id, bundleID: "", name: "", version: "", price: 0, artistName: "", sellerName: "", description: "", averageUserRating: 0, userRatingCount: 0, artworkUrl: "", screenshotUrls: [], minimumOsVersion: "", releaseDate: "", primaryGenreName: "")
        do {
            Diag.log("nhận app: id=\(id)")
            do { try await Purchase.purchase(account: &acc, app: sw) }
            catch let e where "\(e)".contains("2034") || "\(e)".contains("2042") {
                acc = try await ApplePackage.Authenticator.authenticate(email: acc.email, password: acc.password, code: "", cookies: acc.cookie)
                try await Purchase.purchase(account: &acc, app: sw)
            }
            store.save(acc)
            job.status = "Apple đã chấp nhận: app \(id) đã được thêm vào tài khoản. Mục “Đã mua” trong App Store có thể cập nhật chậm vài phút."
        } catch {
            Diag.log("nhận app: lỗi \(error)")
            job.error = error.localizedDescription
        }
    }

    private func listVersions() async {
        guard var acc = store.account(email), let id = appID else { return }
        listing = true; job.error = nil; job.status = ""
        defer { listing = false }
        do {
            versions = try await StoreClient.versions(account: &acc, appID: id).reversed()
            store.save(acc)
            showVersions = true
        } catch { job.error = error.localizedDescription }
    }

    private func meta(_ f: URL) -> (name: String, bundle: String, version: String) {
        var name = f.deletingPathExtension().lastPathComponent, bundle = "", version = "1.0"
        if let d = try? Data(contentsOf: f.appendingPathExtension("json")), let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            name = m["name"] ?? name; bundle = m["bundle"] ?? ""; version = m["version"] ?? version
        }
        return (name, bundle, version)
    }

    @ViewBuilder private func icon(_ f: URL) -> some View {
        if let d = try? Data(contentsOf: f.appendingPathExtension("png")), let img = UIImage(data: d) {
            Image(uiImage: img).resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.gray.opacity(0.25)).frame(width: 48, height: 48)
                .overlay(Image(systemName: "app.dashed").foregroundColor(.secondary))
        }
    }

    private func install(_ f: URL) {
        var name = f.deletingPathExtension().lastPathComponent, bundle = "", version = "1.0"
        if let d = try? Data(contentsOf: f.appendingPathExtension("json")), let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            name = m["name"] ?? name; bundle = m["bundle"] ?? ""; version = m["version"] ?? version
        }
        if bundle.isEmpty {
            let base = f.deletingPathExtension().lastPathComponent
            if let i = base.lastIndex(of: "_") { bundle = String(base[..<i]); version = String(base[base.index(after: i)...]) } else { bundle = base }
        }
        job.error = nil
        job.status = "Đang mở trình cài đặt của iOS…"
        LocalInstaller.shared.onSent = { job.status = "iOS đã tải xong gói, đang cài. Xem biểu tượng trên màn hình chính." }
        LocalInstaller.shared.install(ipa: f, bundleID: bundle, name: name, version: version) { err in
            if let err { job.status = ""; job.error = err }
            else { job.status = "Hãy bấm “Cài đặt” trên hộp thoại của iOS. Giữ app mở đến khi biểu tượng xuất hiện." }
        }
    }

    private func refresh() {
        let list = (try? FileManager.default.contentsOfDirectory(at: DownloadJob.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        files = list.filter { $0.pathExtension == "ipa" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    private func size(_ u: URL) -> String {
        let n = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
