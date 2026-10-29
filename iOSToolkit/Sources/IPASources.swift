import SwiftUI
import Foundation

private struct IPASource: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    /// Icon của chính nguồn (field "iconURL"/"headerURL"/"image" ở gốc JSON — kiểu AltStore/SideStore),
    /// không phải icon của từng app bên trong. nil nếu JSON nguồn không khai báo.
    var iconURLString: String?

    var iconURL: URL? {
        guard let iconURLString else { return nil }
        return URL(string: iconURLString, relativeTo: URL(string: url))?.absoluteURL
    }

    /// Dự phòng khi nguồn không khai báo icon riêng: favicon theo domain qua dịch vụ công khai của Google.
    var faviconURL: URL? {
        guard let host = URL(string: url)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(host)")
    }
}

/// Icon khai báo ở GỐC JSON của nguồn (khác icon riêng của từng app) — đúng kiểu AltStore/SideStore,
/// ví dụ các field "iconURL"/"headerURL"/"image"/"icon" ở cấp ngoài cùng của tệp.
private func repoIconURLString(from object: [String: Any]) -> String? {
    for key in ["iconURL", "headerURL", "image", "icon"] {
        if let s = object[key] as? String, !s.isEmpty { return s }
    }
    return nil
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
    @State private var activeDownloadTask: URLSessionDownloadTask?
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
                                handleTap(app)
                            } label: {
                                appRowContent(app)
                            }
                            .buttonStyle(.plain)
                            .disabled(downloadingID != nil && downloadingID != app.id)
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
                            HStack(spacing: 12) {
                                AsyncImage(url: source.iconURL ?? source.faviconURL) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Image(systemName: "globe").resizable().scaledToFit().padding(8).foregroundStyle(.secondary)
                                }
                                .frame(width: 36, height: 36)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
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
                    ZStack(alignment: .leading) {
                        // Tự vẽ placeholder màu xám thay vì dùng `prompt:` của TextField: trên
                        // field kiểu URL, iOS tự tô prompt hệ thống màu xanh (kiểu liên kết) bất
                        // kể foregroundColor đặt trên Text — kể cả khi bỏ textContentType(.URL).
                        if newURL.isEmpty {
                            // Text(verbatim:) thay vì Text(_ literal:) — chuỗi literal đi qua
                            // LocalizedStringKey/Markdown của SwiftUI, nên một chuỗi NHÌN GIỐNG URL
                            // tự bị hệ thống tô "data detector" màu xanh kiểu liên kết, bất kể
                            // foregroundStyle. verbatim: bỏ qua hẳn bước đó, hiển thị chữ thô.
                            Text(verbatim: "https://example.com/repo.json")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $newURL)
                            .foregroundStyle(.primary)
                    }
                    .font(.body)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("URL nguồn JSON")
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tìm ứng dụng theo tên")
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
        .task { await backfillIcons() }
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

    /// Các nguồn đã lưu từ trước khi có field icon riêng (hoặc lúc thêm chưa đọc được icon) sẽ
    /// chưa có iconURLString — âm thầm tải lại JSON của nguồn một lần để lấy icon thật của repo,
    /// thay vì chỉ dùng favicon dự phòng.
    @MainActor
    private func backfillIcons() async {
        for source in sources where source.iconURLString == nil {
            guard let url = URL(string: source.url) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let icon = repoIconURLString(from: object) else { continue }
                if let idx = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[idx].iconURLString = icon
                }
            } catch {
                continue
            }
        }
        persist()
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
            sources.append(IPASource(name: name, url: url.absoluteString, iconURLString: repoIconURLString(from: object)))
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
            if source.iconURLString == nil, let icon = repoIconURLString(from: object),
               let idx = sources.firstIndex(where: { $0.id == source.id }) {
                sources[idx].iconURLString = icon
                activeSource = sources[idx]
                persist()
            }
        } catch {
            message = "Không tải được danh sách ứng dụng: \(error.localizedDescription)"
        }
    }


    @ViewBuilder
    private func appRow(_ app: RepoApp) -> some View {
        Button {
            handleTap(app)
        } label: {
            appRowContent(app)
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil && downloadingID != app.id)
    }

    /// Giống nút tải trên App Store: lần nhấn đầu bắt đầu tải, nhấn lần nữa trong lúc đang tải
    /// (nút đang hiện vòng tiến trình + ô vuông ở giữa) sẽ huỷ tải thay vì tải lại từ đầu.
    private func handleTap(_ app: RepoApp) {
        if downloadingID == app.id {
            activeDownloadTask?.cancel()
        } else {
            Task { await download(app) }
        }
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
                downloadRing
            } else {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    /// Nút tải kiểu App Store: vòng tròn tiến trình + ô vuông bo góc ở giữa (nút dừng).
    /// Nhấn vào hàng lúc này (xem handleTap) sẽ huỷ tải thay vì tải lại.
    @ViewBuilder
    private var downloadRing: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(downloadProgress, 0.015))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: downloadProgress)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
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
        defer { downloadingID = nil; downloadProgress = 0; activeDownloadTask = nil }
        do {
            var request = URLRequest(url: app.downloadURL)
            request.timeoutInterval = 120
            let temporaryURL = try await Self.downloadWithProgress(request: request) { fraction in
                Task { @MainActor in downloadProgress = fraction }
            } onTaskCreated: { task in
                Task { @MainActor in activeDownloadTask = task }
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Source-\(UUID().uuidString)-\(app.name.replacingOccurrences(of: "/", with: "-")).ipa")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            onDownloaded(destination)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                message = "Đã huỷ tải \(app.name)."
            } else {
                message = "Tải IPA thất bại: \(error.localizedDescription)"
            }
        }
    }

    /// Tải file bằng URLSessionDownloadTask (thay vì API async `download(for:)` không có tiến trình
    /// và không huỷ được giữa chừng) để theo dõi `fractionCompleted` cho vòng tiến trình, và trả
    /// về chính task để nhấn lần hai có thể gọi `task.cancel()` giống nút tải trên App Store.
    private static func downloadWithProgress(
        request: URLRequest,
        onProgress: @escaping (Double) -> Void,
        onTaskCreated: @escaping (URLSessionDownloadTask) -> Void
    ) async throws -> URL {
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
            onTaskCreated(task)
            box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
            task.resume()
        }
    }
}
