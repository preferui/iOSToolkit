import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

// MARK: - Lõi edit / nhân bản IPA

enum IPACloneError: LocalizedError {
    case badZip, noApp, badInfoPlist, noOutput, writeFailed(Error)
    var errorDescription: String? {
        switch self {
        case .badZip: return "Không mở được tệp (không phải .ipa/.zip hợp lệ, hoặc bị hỏng)."
        case .noApp: return "Không tìm thấy thư mục Payload/*.app bên trong — đây có phải là file IPA không?"
        case .badInfoPlist: return "Không đọc được Info.plist của app."
        case .noOutput: return "Không tạo được bản IPA mới."
        case let .writeFailed(e): return "Ghi tệp thất bại: \(e.localizedDescription)"
        }
    }
}

struct IPALoaded {
    var srcURL: URL
    var appFolder: String      // ví dụ "Payload/Foo.app/"
    var originalBundleID: String
    var originalDisplayName: String
}

struct IPACloneSpec: Identifiable {
    let id = Int.random(in: 0...Int.max)
    var displayName: String
    var bundleID: String
}

enum IPACloner {
    /// Tìm đường dẫn "Payload/<Tên>.app/" bằng cách tìm thẳng tệp Info.plist của nó — không
    /// dựa vào việc zip có liệt kê entry thư mục riêng hay không (nhiều zip không có).
    static func findAppFolder(in archive: Archive) -> String? {
        for e in archive where e.type == .file {
            let comps = e.path.components(separatedBy: "/")
            if comps.count == 3, comps[0] == "Payload", comps[1].lowercased().hasSuffix(".app"), comps[2] == "Info.plist" {
                return "Payload/\(comps[1])/"
            }
        }
        return nil
    }

    /// Mở ipa/zip, tìm Payload/*.app/Info.plist, đọc tên + bundle id hiện tại.
    static func load(_ src: URL) throws -> IPALoaded {
        guard let archive = try? Archive(url: src, accessMode: .read) else { throw IPACloneError.badZip }
        guard let appFolder = findAppFolder(in: archive) else { throw IPACloneError.noApp }

        let infoPath = appFolder + "Info.plist"
        guard let entry = archive[infoPath] else { throw IPACloneError.badInfoPlist }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw IPACloneError.badInfoPlist
        }
        let bid = (plist["CFBundleIdentifier"] as? String) ?? ""
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? ""
        return IPALoaded(srcURL: src, appFolder: appFolder, originalBundleID: bid, originalDisplayName: name)
    }

    /// Tạo một bản IPA mới theo `spec`, thay icon nếu có `iconPNGBySize` (key = tên tệp icon rời,
    /// value = dữ liệu PNG). Luôn gỡ chữ ký cũ (_CodeSignature, embedded.mobileprovision) vì đổi
    /// bundle id/nội dung là chữ ký cũ chắc chắn không còn hợp lệ nữa.
    static func makeClone(from loaded: IPALoaded, spec: IPACloneSpec, iconPNGBySize: [String: Data], outDir: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipaclone-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: loaded.srcURL, to: work)
        defer { try? FileManager.default.removeItem(at: work) }

        guard let archive = try? Archive(url: work, accessMode: .update) else { throw IPACloneError.badZip }

        // 1) Sửa Info.plist: bundle id, tên hiển thị, (nếu có icon mới) khai báo CFBundleIcons.
        let infoPath = loaded.appFolder + "Info.plist"
        guard let infoEntry = archive[infoPath] else { throw IPACloneError.badInfoPlist }
        var infoData = Data()
        _ = try? archive.extract(infoEntry) { infoData.append($0) }
        guard var plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw IPACloneError.badInfoPlist
        }
        plist["CFBundleIdentifier"] = spec.bundleID
        plist["CFBundleDisplayName"] = spec.displayName
        plist["CFBundleName"] = spec.displayName

        if !iconPNGBySize.isEmpty {
            let iphoneFiles = ["AppIcon60x60"]
            let ipadFiles = ["AppIcon60x60", "AppIcon76x76"]
            plist["CFBundleIcons"] = [
                "CFBundlePrimaryIcon": ["CFBundleIconFiles": iphoneFiles, "CFBundleIconName": "AppIcon"] as [String: Any]
            ]
            plist["CFBundleIcons~ipad"] = [
                "CFBundlePrimaryIcon": ["CFBundleIconFiles": ipadFiles, "CFBundleIconName": "AppIcon"] as [String: Any]
            ]
        }

        guard let newInfoData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else {
            throw IPACloneError.badInfoPlist
        }
        try archive.remove(infoEntry)
        try archive.addEntry(with: infoPath, type: .file, uncompressedSize: Int64(newInfoData.count), compressionMethod: .deflate) { pos, size in
            newInfoData.subdata(in: Int(pos) ..< Int(pos) + size)
        }

        // 2) Gỡ chữ ký cũ.
        for path in archive.map({ $0.path }) {
            let rel = path.hasPrefix(loaded.appFolder) ? String(path.dropFirst(loaded.appFolder.count)) : path
            if rel.hasPrefix("_CodeSignature/") || rel == "embedded.mobileprovision" {
                if let e = archive[path] { try? archive.remove(e) }
            }
        }

        // 3) Thêm icon rời (nếu có).
        for (name, data) in iconPNGBySize {
            let path = loaded.appFolder + name
            if let existing = archive[path] { try? archive.remove(existing) }
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos) ..< Int(pos) + size)
            }
        }

        let safeName = spec.bundleID.isEmpty ? "app" : spec.bundleID.replacingOccurrences(of: "/", with: "_")
        let outURL = outDir.appendingPathComponent("\(safeName).ipa")
        try? FileManager.default.removeItem(at: outURL)
        do {
            try FileManager.default.copyItem(at: work, to: outURL)
        } catch { throw IPACloneError.writeFailed(error) }
        return outURL
    }

    /// Sinh các icon rời cỡ chuẩn từ 1 ảnh gốc (tên tệp khớp quy ước CFBundleIconFiles ở trên).
    static func iconFiles(from image: UIImage) -> [String: Data] {
        let specs: [(name: String, points: CGFloat)] = [
            ("AppIcon60x60@2x.png", 60 * 2),
            ("AppIcon60x60@3x.png", 60 * 3),
            ("AppIcon76x76~ipad.png", 76),
            ("AppIcon76x76@2x~ipad.png", 76 * 2),
        ]
        var out: [String: Data] = [:]
        for s in specs {
            let size = CGSize(width: s.points, height: s.points)
            let renderer = UIGraphicsImageRenderer(size: size)
            let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let data = resized.pngData() { out[s.name] = data }
        }
        return out
    }
}

// MARK: - Giao diện

struct IPACloneToolView: View {
    @State private var srcURL: URL?
    @State private var scoped: URL?
    @State private var loaded: IPALoaded?
    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var copies = 1
    @State private var iconPickerItem: PhotosPickerItem?
    @State private var iconImage: UIImage?
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var exportURLs: [URL] = []
    @FocusState private var focus: Bool

    var body: some View {
        Form {
            Section {
                Button { pickIPA() } label: {
                    HStack {
                        Image(systemName: "shippingbox")
                        Text(srcURL?.lastPathComponent ?? "Chọn tệp .ipa…").lineLimit(1)
                    }
                }
            } header: { Text("Tệp IPA gốc") } footer: {
                Text("Chọn một tệp .ipa (chưa ký hoặc đã ký đều được — chữ ký cũ sẽ bị gỡ vì không còn hợp lệ sau khi đổi).")
            }

            if let loaded {
                Section("Thông tin gốc") {
                    LabeledContent("Bundle ID", value: loaded.originalBundleID)
                    LabeledContent("Tên hiển thị", value: loaded.originalDisplayName)
                }

                Section {
                    TextField("Tên hiển thị mới", text: $displayName).focused($focus)
                    TextField("Bundle ID mới", text: $bundleID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus)
                    Stepper("Số bản sao: \(copies)", value: $copies, in: 1...20)
                } header: { Text("Chỉnh sửa") } footer: {
                    Text(copies > 1 ? "Từ bản sao thứ 2 trở đi, Bundle ID và tên sẽ tự thêm số thứ tự (ví dụ \(bundleID).c2, \(bundleID).c3…) để cài song song được." : "Đổi Bundle ID để cài song song với app gốc trên cùng máy.")
                }

                Section {
                    PhotosPicker(selection: $iconPickerItem, matching: .images) {
                        HStack {
                            if let iconImage {
                                Image(uiImage: iconImage).resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                Image(systemName: "photo").frame(width: 44, height: 44)
                            }
                            Text(iconImage == nil ? "Chọn icon mới (tuỳ chọn)" : "Đổi icon khác")
                        }
                    }
                    if iconImage != nil {
                        Button("Bỏ icon mới, giữ icon gốc", role: .destructive) { iconImage = nil; iconPickerItem = nil }
                    }
                } header: { Text("Icon") }

                Section {
                    Button {
                        focus = false
                        run()
                    } label: { HStack { Image(systemName: "rectangle.on.rectangle"); Text(busy ? "Đang tạo…" : "Tạo IPA"); if busy { Spacer(); ProgressView() } } }
                    .disabled(bundleID.isEmpty || displayName.isEmpty || busy)
                }

                if !exportURLs.isEmpty {
                    Section {
                        ShareLink(items: exportURLs) {
                            Label(exportURLs.count > 1 ? "Lưu/chia sẻ \(exportURLs.count) bản IPA" : "Lưu/chia sẻ bản IPA", systemImage: "square.and.arrow.up")
                        }
                        if SignStore.hasAny(), let first = exportURLs.first {
                            NavigationLink { SignToolView(initialIPA: first) } label: {
                                Label("Chuyển qua phần ký", systemImage: "signature")
                            }
                        }
                    } footer: {
                        Text(SignStore.hasAny()
                            ? "Có thể ký ngay bằng chứng chỉ đã nhập, hoặc lưu bản IPA chưa ký để tự ký bằng công cụ khác."
                            : "Chọn “Lưu vào Tệp” trong hộp chia sẻ để lưu lại, rồi tự ký bằng công cụ bạn đang dùng (ví dụ TrollStore Lite), hoặc vào mục “Ký IPA” để nhập chứng chỉ và ký ngay trong app.")
                    }
                }
            }
        }
        .navigationTitle("Nhân bản / Edit IPA")
        .scrollDismissesKeyboard(.immediately)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Xong") { focus = false } } }
        .overlay(alignment: .top) { banner }
        .animation(.easeInOut(duration: 0.2), value: message)
        .onChange(of: iconPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    iconImage = img
                }
            }
        }
        .onDisappear { scoped?.stopAccessingSecurityScopedResource(); scoped = nil }
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

    private func pickIPA() {
        focus = false
        DocPicker.present(types: [.zip, .data, .item], asCopy: true) { urls in
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            guard ext == "ipa" || ext == "zip" else { isError = true; message = "Tệp “\(url.lastPathComponent)” không phải .ipa/.zip."; return }
            scoped?.stopAccessingSecurityScopedResource()
            let ok = url.startAccessingSecurityScopedResource()
            Diag.log("ipaclone: chọn \(url.lastPathComponent), quyền truy cập=\(ok)")
            srcURL = url; exportURLs = []; message = nil
            do {
                let l = try IPACloner.load(url)
                loaded = l
                displayName = l.originalDisplayName
                bundleID = l.originalBundleID
            } catch {
                loaded = nil
                isError = true
                message = error.localizedDescription
            }
        }
    }

    private func run() {
        guard let loaded else { return }
        busy = true; message = nil; exportURLs = []
        let baseName = displayName, baseID = bundleID, n = copies
        let icon = iconImage
        Diag.log("ipaclone: tạo \(n) bản từ \(loaded.srcURL.lastPathComponent) -> \(baseID)")
        Task {
            do {
                let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("IPAClone-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let iconFiles = icon.map { IPACloner.iconFiles(from: $0) } ?? [:]

                var urls: [URL] = []
                for i in 1...n {
                    let spec: IPACloneSpec = i == 1
                        ? IPACloneSpec(displayName: baseName, bundleID: baseID)
                        : IPACloneSpec(displayName: "\(baseName) \(i)", bundleID: "\(baseID).c\(i)")
                    let url = try await Task.detached {
                        try IPACloner.makeClone(from: loaded, spec: spec, iconPNGBySize: iconFiles, outDir: outDir)
                    }.value
                    urls.append(url)
                }
                exportURLs = urls
                isError = false
                message = n > 1 ? "Đã tạo \(n) bản IPA." : "Đã tạo xong IPA mới."
                Diag.log("ipaclone: xong, \(urls.count) tệp")
            } catch {
                isError = true
                message = error.localizedDescription
                Diag.log("ipaclone: lỗi \(error)")
            }
            busy = false
        }
    }
}
