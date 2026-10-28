import SwiftUI
import Foundation

private struct IPASource: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
}

private struct RepoApp: Identifiable {
    var id: String { "\(name)|\(version)|\(downloadURL)" }
    let name: String
    let version: String
    let description: String
    let iconURL: URL?
    let downloadURL: URL

    init?(json: [String: Any], baseURL: URL) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let version = json["version"] as? String ?? ""
        let description = json["localizedDescription"] as? String ?? json["subtitle"] as? String ?? ""
        let rawDownload = (json["downloadURL"] as? String) ?? (json["down"] as? String) ?? (json["url"] as? String) ?? ""
        guard let download = URL(string: rawDownload, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(download.scheme?.lowercased() ?? ""),
              download.pathExtension.lowercased() == "ipa" else { return nil }
        self.name = name
        self.version = version
        self.description = description
        let rawIcon = (json["iconURL"] as? String) ?? (json["icon"] as? String) ?? ""
        self.iconURL = URL(string: rawIcon, relativeTo: baseURL)?.absoluteURL
        self.downloadURL = download
    }
}

struct IPASourcesView: View {
    var onDownloaded: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("ioskit.ipa.sources.v1") private var savedSources = ""
    @State private var sources: [IPASource] = []
    @State private var activeSource: IPASource?
    @State private var apps: [RepoApp] = []
    @State private var searchText = ""
    @State private var newURL = ""
    @State private var loading = false
    @State private var downloadingID: String?
    @State private var message = ""

    private let defaultURL = "https://repository.apptesters.org/"

    private var visibleApps: [RepoApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) || $0.version.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let activeSource {
                Section {
                    HStack {
                        Button {
                            self.activeSource = nil
                            apps = []
                            message = ""
                        } label: {
                            Label("Tất cả nguồn", systemImage: "chevron.left")
                        }
                        Spacer()
                        Text(activeSource.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Section {
                    if loading && apps.isEmpty {
                        HStack { ProgressView(); Text("Đang tải danh sách ứng dụng…").foregroundStyle(.secondary) }
                    } else if visibleApps.isEmpty {
                        Text(searchText.isEmpty ? "Nguồn chưa có ứng dụng IPA tương thích hoặc định dạng JSON chưa được hỗ trợ." : "Không tìm thấy ứng dụng phù hợp.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleApps) { app in
                            Button {
                                Task { await download(app) }
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: app.iconURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "app.dashed").resizable().scaledToFit().padding(10).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(app.name).font(.headline).foregroundStyle(.primary)
                                        if !app.version.isEmpty {
                                            Text("Phiên bản \(app.version)").font(.caption).foregroundStyle(.secondary)
                                        }
                                        if !app.description.isEmpty {
                                            Text(app.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if downloadingID == app.id {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(downloadingID != nil)
                        }
                    }
                } header: {
                    Text("Ứng dụng (\(visibleApps.count))")
                }
            } else {
                Section("Nguồn IPA") {
                    ForEach(sources) { source in
                        Button {
                            Task { await open(source) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).font(.headline).foregroundStyle(.primary)
                                    Text(source.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(loading)
                        .swipeActions {
                            Button(role: .destructive) { remove(source) } label: {
                                Label("Xoá", systemImage: "trash")
                            }
                        }
                    }
                }
                Section("Thêm nguồn JSON") {
                    TextField("https://example.com/repo.json", text: $newURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await addSource() }
                    } label: {
                        HStack {
                            Text(loading ? "Đang kiểm tra nguồn…" : "Thêm nguồn")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading || newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !message.isEmpty {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .searchable(text: $searchText, prompt: activeSource == nil ? "Tìm nguồn IPA" : "Tìm ứng dụng")
        .navigationTitle(activeSource?.name ?? "Nguồn IPA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Đóng") { dismiss() }
            }
        }
        .onAppear(perform: loadSavedSources)
    }

    private func loadSavedSources() {
        if let data = savedSources.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([IPASource].self, from: data), !decoded.isEmpty {
            sources = decoded
        } else {
            sources = [IPASource(name: "AppTesters", url: defaultURL)]
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources),
              let string = String(data: data, encoding: .utf8) else { return }
        savedSources = string
    }

    private func remove(_ source: IPASource) {
        sources.removeAll { $0.id != source.id }
        persist()
    }

    private func addSource() async {
        let raw = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: normalized), let host = url.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            message = "URL nguồn không hợp lệ."
            return
        }
        guard !sources.contains(where: { $0.url.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            message = "Nguồn này đã được thêm."
            return
        }
        loading = true
        message = ""
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let root = try JSONSerialization.jsonObject(with: data)
            guard let object = root as? [String: Any] else {
                message = "JSON nguồn không đúng định dạng."
                return
            }
            let name = (object["name"] as? String) ?? (object["repoName"] as? String) ?? host
            sources.append(IPASource(name: name, url: url.absoluteString))
            persist()
            newURL = ""
            message = "Đã thêm nguồn \(name)."
        } catch {
            message = "Không đọc được JSON nguồn: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func open(_ source: IPASource) async {
        activeSource = source
        apps = []
        loading = true
        message = ""
        defer { loading = false }
        guard let url = URL(string: source.url) else {
            message = "URL nguồn không hợp lệ."
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                message = "Máy chủ trả về HTTP \(http.statusCode)."
                return
            }
            let root = try JSONSerialization.jsonObject(with: data)
            guard let object = root as? [String: Any], let rawApps = object["apps"] as? [[String: Any]] else {
                message = "JSON không có danh sách apps hợp lệ."
                return
            }
            apps = rawApps.compactMap { RepoApp(json: $0, baseURL: url) }
            if apps.isEmpty {
                message = "Đã đọc JSON nhưng không tìm thấy mục nào có liên kết IPA trực tiếp."
            }
        } catch {
            message = "Không tải được danh sách ứng dụng: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func download(_ app: RepoApp) async {
        downloadingID = app.id
        message = ""
        defer { downloadingID = nil }
        do {
            var request = URLRequest(url: app.downloadURL)
            request.timeoutInterval = 120
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                message = "Không tải được IPA (HTTP \(http.statusCode))."
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Source-\(UUID().uuidString)-\(app.name.replacingOccurrences(of: "/", with: "-")).ipa")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            onDownloaded(destination)
        } catch {
            message = "Tải IPA thất bại: \(error.localizedDescription)"
        }
    }
}
