import Foundation
import SwiftUI
import SafariServices

private struct IPASource: Identifiable, Codable, Equatable {
    var id: String { url }
    let name: String
    let url: String
}

private enum IPASourceStore {
    static let key = "ioskit.ipa.sources.v1"
    static let initial = "https://repository.apptesters.org"
    static func load() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        return saved.isEmpty ? [initial] : saved
    }
    static func save(_ values: [String]) { UserDefaults.standard.set(values, forKey: key) }
}

struct IPASourcesView: View {
    @State private var sources = IPASourceStore.load()
    @State private var selected = IPASourceStore.initial
    @State private var newURL = ""
    @State private var items: [IPASource] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var showAdd = false

    private var filtered: [IPASource] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            Section {
                Picker("Nguồn", selection: $selected) {
                    ForEach(sources, id: \.self) { Text(URL(string: $0)?.host ?? $0).tag($0) }
                }
                .onChange(of: selected) { _, _ in items = []; error = nil }
                Button { showAdd = true } label: { Label("Thêm nguồn", systemImage: "plus.circle") }
                if sources.count > 1 {
                    Button(role: .destructive) {
                        sources.removeAll { $0 == selected }
                        IPASourceStore.save(sources)
                        selected = sources.first ?? IPASourceStore.initial
                        items = []
                    } label: { Label("Xoá nguồn đang chọn", systemImage: "trash") }
                }
            } footer: {
                Text("Danh sách chỉ được tải khi bạn nhấn Tải danh sách. Mỗi lần chỉ đọc tối đa 40 liên kết IPA để hạn chế lag và dùng ít bộ nhớ.")
            }

            Section("IPA trong nguồn") {
                TextField("Tìm tên IPA", text: $query)
                Button {
                    Task { await loadItems() }
                } label: {
                    HStack {
                        Label("Tải danh sách", systemImage: "arrow.clockwise")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(loading)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if !items.isEmpty {
                    Text("Hiển thị \(filtered.count) / \(items.count) mục").font(.caption).foregroundStyle(.secondary)
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name).font(.subheadline).lineLimit(2)
                            ShareLink(item: URL(string: item.url)!) {
                                Label("Chia sẻ liên kết tải", systemImage: "square.and.arrow.up")
                                    .font(.caption)
                            }
                        }
                    }
                } else if !loading && error == nil {
                    Text("Chưa tải danh sách.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Nguồn IPA")
        .alert("Thêm nguồn IPA", isPresented: $showAdd) {
            TextField("https://example.com/repo", text: $newURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Huỷ", role: .cancel) {}
            Button("Thêm") {
                let raw = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let u = URL(string: raw), u.scheme == "https", u.host != nil else { error = "Hãy nhập địa chỉ HTTPS hợp lệ."; return }
                if !sources.contains(u.absoluteString) { sources.append(u.absoluteString); IPASourceStore.save(sources) }
                selected = u.absoluteString
                newURL = ""
                items = []
                error = nil
            }
        } message: {
            Text("Nhập địa chỉ trang nguồn chứa các liên kết IPA.")
        }
    }

    @MainActor private func loadItems() async {
        guard let url = URL(string: selected) else { error = "Địa chỉ nguồn không hợp lệ."; return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 iOSToolkit", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                error = "Nguồn không trả về HTTP thành công."
                return
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                error = "Không đọc được nội dung nguồn."
                return
            }
            let pattern = #"(?i)href\s*=\s*["']([^"']+\.ipa(?:\?[^"']*)?)["']"#
            let regex = try NSRegularExpression(pattern: pattern)
            let ns = html as NSString
            var found: [IPASource] = []
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(40) {
                guard match.numberOfRanges > 1 else { continue }
                let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
                guard let itemURL = URL(string: raw, relativeTo: url)?.absoluteURL, itemURL.scheme == "https" else { continue }
                let name = itemURL.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? itemURL.lastPathComponent
                if !found.contains(where: { $0.url == itemURL.absoluteString }) {
                    found.append(IPASource(name: name, url: itemURL.absoluteString))
                }
            }
            items = found
            if found.isEmpty { error = "Không tìm thấy liên kết IPA trực tiếp trong trang này. Nguồn có thể dùng API hoặc cấu trúc riêng." }
        } catch {
            self.error = "Không tải được nguồn: \(error.localizedDescription)"
        }
    }
}
