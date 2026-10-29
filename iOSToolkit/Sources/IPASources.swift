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
    let sourceName: String

    init?(json: [String: Any], baseURL: URL, sourceName: String = "") {
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
        self.sourceName = sourceName
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
    @State private var downloadProgress: Double = 0
    @State private var message = ""
    @State private var globalSearchResults: [RepoApp] = []
    @State private var searchingAllSources = false
    @State private var searchTask: Task<Void, Never>?

    private let defaultURL = "https://repository.apptesters.org/"

    private var visibleApps: [RepoApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activeSource == nil ? apps : apps }
        let base = activeSource == nil && !globalSearchResults.isEmpty ? globalSearchResults : apps
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) || $0.version.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if activeSource == nil && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    if searchingAllSources {
                        HStack { ProgressView(); Text("Đang tìm ứng dụng trong các nguồn…").foregroundStyle(.secondary) }
                    } else if visibleApps.isEmpty {
                        Text("Không tìm thấy ứng dụng phù hợp.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleApps) { app in
                            appRow(app)
                        }
                    }
                } header: {
                    Text("Ứng dụng phù hợp (\(visibleApps.count))")
                }
            } else if let activeSource {
                Section {
                    HStack {
                        Button {
                            self.activeSource = nil
                            apps = []
                            globalSearchResults = []
                            searchText = ""
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
                                appRowContent(app)
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
                    TextField(text: $newURL, prompt: Text("https://example.com/repo.json").foregroundColor(.secondary)) {
                        Text("URL nguồn JSON")
                    }
                    .font(.body)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
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
        .searchable(text: $searchText, prompt: "Tìm ứng dụng theo tên")
        .onChange(of: searchText) { value in
            searchTask?.cancel()
            let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard activeSource == nil, !query.isEmpty else {
                globalSearchResults = []
                return
            }
            searchTask = Task { await searchAcrossSources(query: query) }
        }
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
            apps = rawApps.compactMap { RepoApp(json: $0, baseURL: url, sourceName: source.name) }
            if apps.isEmpty {
                message = "Đã đọc JSON nhưng không tìm thấy mục nào có liên kết IPA trực tiếp."
            }
        } catch {
            message = "Không tải được danh sách ứng dụng: \(error.localizedDescription)"
        }
    }


    @ViewBuilder
    private func appRow(_ app: RepoApp) -> some View {
        Button {
            Task { await download(app) }
        } label: {
            appRowContent(app)
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
    }

    @ViewBuilder
    private func appRowContent(_ app: RepoApp) -> some View {
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
                if !app.sourceName.isEmpty {
                    Text(app.sourceName).font(.caption2).foregroundStyle(.secondary)
                }
                if !app.description.isEmpty {
                    Text(app.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if downloadingID == app.id {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: downloadProgress)
                        .frame(width: 56)
                    Text(downloadProgress > 0 ? "\(Int(downloadProgress * 100))%" : "Đang tải…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @MainActor
    private func searchAcrossSources(query: String) async {
        searchingAllSources = true
        defer { searchingAllSources = false }
        var found: [RepoApp] = []
        for source in sources {
            if Task.isCancelled { return }
            guard let url = URL(string: source.url) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawApps = root["apps"] as? [[String: Any]] else { continue }
                let matching = rawApps.compactMap { RepoApp(json: $0, baseURL: url, sourceName: source.name) }
                    .filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) || $0.version.localizedCaseInsensitiveContains(query) }
                found.append(contentsOf: matching)
            } catch {
                continue
            }
        }
        if !Task.isCancelled {
            globalSearchResults = found
        }
    }

    @MainActor
    private func download(_ app: RepoApp) async {
        downloadingID = app.id
        downloadProgress = 0
        message = ""
        defer { downloadingID = nil; downloadProgress = 0 }
        do {
            var request = URLRequest(url: app.downloadURL)
            request.timeoutInterval = 120
            let temporaryURL = try await Self.downloadWithProgress(request: request) { fraction in
                Task { @MainActor in downloadProgress = fraction }
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Source-\(UUID().uuidString)-\(app.name.replacingOccurrences(of: "/", with: "-")).ipa")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            onDownloaded(destination)
        } catch {
            message = "Tải IPA thất bại: \(error.localizedDescription)"
        }
    }

    /// Tải file bằng URLSessionDownloadTask (thay vì API async `download(for:)` không có tiến trình)
    /// để theo dõi được `fractionCompleted` và hiển thị thanh tiến trình thật khi tải IPA từ nguồn.
    private static func downloadWithProgress(request: URLRequest, onProgress: @escaping (Double) -> Void) async throws -> URL {
        final class ObserverBox { var observation: NSKeyValueObservation? }
        let box = ObserverBox()
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { url, response, error in
                box.observation?.invalidate()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.resume(throwing: NSError(domain: "IPASources", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Máy chủ trả về HTTP \(http.statusCode)."]))
                    return
                }
                guard let url else {
                    continuation.resume(throwing: NSError(domain: "IPASources", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không nhận được tệp đã tải."]))
                    return
                }
                let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
                do {
                    try FileManager.default.moveItem(at: url, to: stable)
                    continuation.resume(returning: stable)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
            task.resume()
        }
    }
}
