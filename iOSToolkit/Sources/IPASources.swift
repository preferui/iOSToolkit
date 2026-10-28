import SwiftUI
import Foundation

private struct IPASource: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
}

struct IPASourcesView: View {
    @AppStorage("ioskit.ipa.sources.v1") private var savedSources = ""
    @State private var sources: [IPASource] = []
    @State private var selectedID: UUID?
    @State private var newName = ""
    @State private var newURL = ""
    @State private var searchText = ""
    @State private var ipaLinks: [URL] = []
    @State private var isLoading = false
    @State private var message = ""

    private let defaultURL = "https://repository.apptesters.org"

    private var selectedSource: IPASource? {
        sources.first(where: { $0.id == selectedID }) ?? sources.first
    }

    private var filteredLinks: [URL] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ipaLinks }
        return ipaLinks.filter { $0.absoluteString.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section("Nguồn hiện tại") {
                if sources.isEmpty {
                    Text("Chưa có nguồn IPA").foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.headline)
                                Text(source.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if selectedID == source.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                            Button(role: .destructive) {
                                remove(source)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = source.id
                            ipaLinks = []
                            message = ""
                        }
                    }
                }
            }

            Section("Thêm nguồn") {
                TextField("Tên nguồn", text: $newName)
                    .textInputAutocapitalization(.never)
                TextField("https://example.com", text: $newURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Thêm nguồn") { addSource() }
                    .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                Button {
                    Task { await loadLinks() }
                } label: {
                    HStack {
                        if isLoading { ProgressView() }
                        Text(isLoading ? "Đang tìm liên kết IPA…" : "Tìm IPA trong nguồn đã chọn")
                    }
                }
                .disabled(isLoading || selectedSource == nil)

                if !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Tìm kiếm thủ công")
            } footer: {
                Text("Không tự tải toàn bộ kho. Chỉ quét trang HTML khi bạn bấm tìm; tối đa hiển thị 40 liên kết IPA tìm thấy.")
            }

            if !ipaLinks.isEmpty {
                Section("Liên kết IPA (\(filteredLinks.count))") {
                    TextField("Lọc theo tên hoặc URL", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ForEach(filteredLinks, id: \.absoluteString) { url in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(2)
                            ShareLink(item: url) {
                                Label("Mở / chia sẻ liên kết", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Nguồn IPA")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadSavedSources)
    }

    private func loadSavedSources() {
        if let data = savedSources.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([IPASource].self, from: data),
           !decoded.isEmpty {
            sources = decoded
        } else {
            sources = [IPASource(name: "AppTesters", url: defaultURL)]
            persist()
        }
        if selectedID == nil || !sources.contains(where: { $0.id == selectedID }) {
            selectedID = sources.first?.id
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources),
              let string = String(data: data, encoding: .utf8) else { return }
        savedSources = string
    }

    private func addSource() {
        let raw = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            message = "URL nguồn không hợp lệ."
            return
        }
        guard !sources.contains(where: { $0.url.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            message = "Nguồn này đã tồn tại."
            return
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = IPASource(name: name.isEmpty ? (url.host ?? "Nguồn IPA") : name, url: url.absoluteString)
        sources.append(source)
        selectedID = source.id
        newName = ""
        newURL = ""
        ipaLinks = []
        message = "Đã thêm nguồn."
        persist()
    }

    private func remove(_ source: IPASource) {
        sources.removeAll { $0.id == source.id }
        if selectedID == source.id { selectedID = sources.first?.id }
        ipaLinks = []
        persist()
        if sources.isEmpty {
            sources = [IPASource(name: "AppTesters", url: defaultURL)]
            selectedID = sources.first?.id
            persist()
        }
    }

    @MainActor
    private func loadLinks() async {
        guard let source = selectedSource, let url = URL(string: source.url) else { return }
        isLoading = true
        message = ""
        ipaLinks = []
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                message = "Máy chủ trả về mã HTTP \(http.statusCode)."
                return
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                message = "Không đọc được nội dung trang."
                return
            }
            let pattern = #"(?i)href\s*=\s*["']([^"']+\.ipa(?:\?[^"']*)?)["']"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            var found: [URL] = []
            for match in regex.matches(in: html, range: range) {
                guard let r = Range(match.range(at: 1), in: html) else { continue }
                let rawLink = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
                let resolved = URL(string: rawLink, relativeTo: url)?.absoluteURL
                if let resolved, !found.contains(resolved) { found.append(resolved) }
                if found.count >= 40 { break }
            }
            ipaLinks = found
            message = found.isEmpty
                ? "Không tìm thấy liên kết .ipa trực tiếp trên trang này. Nếu nguồn dùng API hoặc trang danh mục động, cần bổ sung bộ phân tích riêng."
                : "Tìm thấy \(found.count) liên kết IPA."
        } catch {
            message = "Không thể tải nguồn: \(error.localizedDescription)"
        }
    }
}
