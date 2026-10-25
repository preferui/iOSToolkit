import SwiftUI
import Foundation

private struct CleanerRecord: Identifiable {
    let app: CleanerApplication
    var usage: LimitedCleanerUsage
    var id: String { app.bundleID }
}

struct CleanerToolView: View {
    @State private var records: [CleanerRecord] = []
    @State private var selected = Set<String>()
    @State private var searchText = ""
    @State private var sortOrder: CleanerSortOrder = .largestFirst
    @State private var scanning = false
    @State private var cleaning = false
    @State private var scanMessage: String?
    @State private var alert: CleanerAlert?
    @State private var accessPrepared = false
    @State private var compatibilityConfirmed = false
    @State private var progressFraction = 0.0
    @State private var progressLabel = "Sẵn sàng"

    private var visibleRecords: [CleanerRecord] {
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let filtered = query.isEmpty ? records : records.filter {
            $0.app.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(query)
                || $0.app.bundleID.localizedCaseInsensitiveContains(query)
        }
        return CleanerCatalog.sorted(
            filtered,
            order: sortOrder,
            size: { $0.usage.totalBytes },
            displayName: { $0.app.name },
            stableID: { $0.id }
        )
    }

    private var totalBytes: Int64 { records.reduce(0) { $0 + $1.usage.totalBytes } }
    private var selectedBytes: Int64 {
        records.reduce(0) { $0 + (selected.contains($1.id) ? $1.usage.totalBytes : 0) }
    }
    private var isBusy: Bool { scanning || cleaning }

    private var currentOS: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    private var currentBuild: String { operatingSystemBuild() }

    private var isCurrentOSSupported: Bool {
        KernelExploit.isApplicable(
            major: currentOS.majorVersion,
            minor: currentOS.minorVersion,
            patch: currentOS.patchVersion,
            build: currentBuild
        )
    }

    private var currentOSDescription: String {
        "\\(currentOS.majorVersion).\\(currentOS.minorVersion).\\(currentOS.patchVersion)"
    }

    var body: some View {
        Group {
            if compatibilityConfirmed {
                cleanerContent
            } else {
                compatibilityGate
            }
        }
    }

    private var compatibilityGate: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: isCurrentOSSupported ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(isCurrentOSSupported ? Color.green : Color.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .center, spacing: 8) {
                        Text("Kiểm tra phiên bản iOS")
                            .font(.title2.weight(.semibold))
                        Text("Cleaner cần xác nhận khả năng tương thích trước khi quét hoặc dọn dữ liệu.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 0) {
                        LabeledContent("Phiên bản hiện tại", value: "iOS \\(currentOSDescription)")
                        Divider().padding(.leading)
                        LabeledContent("Build", value: currentBuild.isEmpty ? "Không xác định" : currentBuild)
                    }
                    .padding(.horizontal, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isCurrentOSSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isCurrentOSSupported ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(isCurrentOSSupported ? "Thiết bị nằm trong danh sách hỗ trợ" : "Phiên bản này chưa được hỗ trợ")
                                .font(.subheadline.weight(.semibold))
                            Text(isCurrentOSSupported
                                 ? "Bạn có thể tiếp tục vào Cleaner. Khả năng tương thích còn phụ thuộc vào thiết bị và cách cài đặt."
                                 : "Cleaner sẽ không chạy quét hay dọn trên phiên bản này. Hãy cập nhật ứng dụng sau khi có bản hỗ trợ phù hợp.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background((isCurrentOSSupported ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Các phiên bản được bật")
                            .font(.subheadline.weight(.semibold))
                        Text("iOS 17.0–17.7.x  ·  iOS 18.0–18.7.1  ·  iOS 26.0.x")
                            .font(.subheadline.monospacedDigit())
                        Text("Bản iOS ngoài danh sách sẽ bị chặn trước khi Cleaner chuẩn bị quyền truy cập.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Button {
                compatibilityConfirmed = true
            } label: {
                Label("Vào Cleaner", systemImage: "arrow.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isCurrentOSSupported)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .navigationTitle("Tương thích")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var cleanerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm ứng dụng", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Xóa tìm kiếm")
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                Section {
                    if isBusy {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progressFraction)
                            HStack(spacing: 8) {
                                Text(progressLabel).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text("\(Int(progressFraction * 100))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue("\(Int(progressFraction * 100))%")
                    }
                    LabeledContent("Có thể giải phóng") { Text(formatBytes(totalBytes)).monospacedDigit() }
                    LabeledContent("Đã chọn") {
                        Text("\(selected.count) ứng dụng · \(formatBytes(selectedBytes))").monospacedDigit()
                    }
                    Button(role: .destructive) { alert = .confirmation } label: {
                        Label(cleaning ? "Đang dọn…" : "Dọn ứng dụng đã chọn", systemImage: "trash")
                    }
                    .disabled(selected.isEmpty || isBusy)
                } header: {
                    Label("Dọn dẹp giới hạn", systemImage: "checkmark.shield")
                } footer: {
                    Text("Chỉ xóa Library/Caches và tmp của ứng dụng đã chọn. Dữ liệu đăng nhập, tài liệu và tệp khác được giữ nguyên.")
                }

                Section {
                    if scanning && records.isEmpty {
                        HStack { ProgressView(); Text(scanMessage ?? "Đang quét ứng dụng…") }
                    } else if visibleRecords.isEmpty {
                        Text(searchText.isEmpty ? "Không tìm thấy dữ liệu tạm có thể dọn." : "Không có ứng dụng khớp tìm kiếm.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleRecords) { record in
                            Button { toggle(record.id) } label: { row(record) }
                                .buttonStyle(.plain)
                                .disabled(cleaning)
                        }
                    }
                } header: {
                    HStack {
                        Text("Ứng dụng (\(visibleRecords.count))")
                        Spacer()
                        if scanning { ProgressView().controlSize(.mini) }
                    }
                } footer: {
                    Text("Chạm để chọn. Kết quả chỉ hiện ứng dụng có tệp trong hai khu vực được phép dọn.")
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Dọn dẹp")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button("Chọn tất cả kết quả") {
                        selected = CleanerCatalog.selectingAllVisible(visibleRecords.map(\.id), preserving: selected)
                    }.disabled(visibleRecords.allSatisfy { selected.contains($0.id) })
                    Button("Bỏ chọn tất cả", role: .destructive) { selected.removeAll() }
                        .disabled(selected.isEmpty)
                } label: { Image(systemName: "checklist") }
                .disabled(isBusy || visibleRecords.isEmpty)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sắp xếp", selection: $sortOrder) {
                        Text("Dung lượng lớn trước").tag(CleanerSortOrder.largestFirst)
                        Text("Dung lượng nhỏ trước").tag(CleanerSortOrder.smallestFirst)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .disabled(isBusy || records.isEmpty)
                Button { scan() } label: {
                    if scanning { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isBusy)
                .accessibilityLabel("Quét lại")
            }
        }
        .task { if !accessPrepared { accessPrepared = true; prepareAndScan() } }
        .alert(item: $alert, content: makeAlert)
    }

    private func row(_ record: CleanerRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22)).foregroundStyle(selected.contains(record.id) ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.app.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(record.app.bundleID).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Cache \(formatBytes(record.usage.cacheBytes)) · Tạm \(formatBytes(record.usage.temporaryBytes))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(formatBytes(record.usage.totalBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func prepareAndScan() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let build = operatingSystemBuild()
        guard KernelExploit.isApplicable(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion,
            build: build
        ) else {
            scanMessage = "Phiên bản iOS/build này chưa nằm trong danh sách 3105 xác nhận hỗ trợ."
            alert = .message(scanMessage!)
            return
        }
        scanning = true
        progressFraction = 0
        progressLabel = "Đang kích hoạt quyền truy cập…"
        scanMessage = "Đang chuẩn bị quyền truy cập thiết bị…"
        DispatchQueue.global(qos: .userInitiated).async {
            let access = CleanerExploitCoordinator.runIfNeeded(progress: { fraction, message in
                DispatchQueue.main.async {
                    progressFraction = min(0.1, max(0, fraction * 0.1))
                    progressLabel = message
                }
            })
            DispatchQueue.main.async {
                guard access else {
                    scanning = false
                    let text = "Không thể chuẩn bị quyền truy cập. Phiên bản iOS/build hoặc cách cài đặt có thể không tương thích. Cleaner chưa quét hay xóa dữ liệu."
                    scanMessage = text
                    alert = .message(text)
                    return
                }
                progressFraction = 0.1
                progressLabel = "Đang liệt kê ứng dụng…"
                scanning = false
                scan()
            }
        }
    }
    private func scan() {
        guard !isBusy else { return }
        scanning = true
        scanMessage = "Đang quét ứng dụng…"
        selected.removeAll()
        records.removeAll()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CleanerContainerStore.installedApplications(progress: { completed, total in
                guard completed.isMultiple(of: 8) || completed == total else { return }
                DispatchQueue.main.async {
                    progressFraction = 0.1 + 0.1 * Double(completed) / Double(max(total, 1))
                    progressLabel = "Đang liệt kê ứng dụng \(completed)/\(total)"
                }
            })
            let applications = result.applications
            var scanned: [CleanerRecord] = []
            let appCount = applications.count
            for (index, app) in applications.enumerated() {
                if let container = CleanerContainerStore.resolveContainer(bundleID: app.bundleID),
                   let usage = try? LimitedCleanerService.scan(
                    containerURL: container,
                    rootValidator: CleanerContainerStore.isApplicationContainer
                   ), usage.totalBytes > 0 {
                    scanned.append(CleanerRecord(app: CleanerApplication(
                        bundleID: app.bundleID,
                        name: app.name,
                        containerPath: container.path
                    ), usage: usage))
                }
                let completed = index + 1
                let fraction = 0.2 + 0.8 * Double(completed) / Double(max(appCount, 1))
                DispatchQueue.main.async {
                    progressFraction = fraction
                    progressLabel = "Đang quét cache \(completed)/\(appCount) ứng dụng"
                }
            }
            DispatchQueue.main.async {
                records = CleanerCatalog.sorted(
                    scanned,
                    order: sortOrder,
                    size: { $0.usage.totalBytes },
                    displayName: { $0.app.name },
                    stableID: { $0.id }
                )
                scanning = false
                scanMessage = result.error
                if let error = result.error, records.isEmpty { alert = .message(error) }
            }
        }
    }

    private func cleanSelected() {
        guard !isBusy else { return }
        let targets = records.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        let totalItems = max(targets.reduce(0) { $0 + $1.usage.removableItemCount }, targets.count)
        cleaning = true
        progressFraction = 0
        progressLabel = "Đang chuẩn bị dọn cache…"
        DispatchQueue.global(qos: .userInitiated).async {
            var changed: [String: LimitedCleanerUsage] = [:]
            var freed: Int64 = 0
            var removed = 0
            var failed = 0
            var processedItems = 0

            for (index, record) in targets.enumerated() {
                let expectedItems = max(record.usage.removableItemCount, 1)
                let publishProgress: (Int) -> Void = { currentItems in
                    let done = min(totalItems, processedItems + min(currentItems, expectedItems))
                    let fraction = Double(done) / Double(totalItems)
                    DispatchQueue.main.async {
                        progressFraction = fraction
                        progressLabel = "Đang dọn \(record.app.name) (\(index + 1)/\(targets.count))"
                    }
                }

                guard let container = CleanerContainerStore.resolveContainer(bundleID: record.app.bundleID) else {
                    failed += 1
                    processedItems += expectedItems
                    publishProgress(0)
                    continue
                }
                do {
                    let result = try LimitedCleanerService.clean(
                        containerURL: container,
                        rootValidator: CleanerContainerStore.isApplicationContainer,
                        initialUsage: record.usage,
                        progress: { current, _ in
                            if current.isMultiple(of: 16) || current >= expectedItems {
                                publishProgress(current)
                            }
                        }
                    )
                    changed[record.id] = result.after
                    freed += result.freedBytes
                    removed += result.removedItemCount
                    failed += result.failedItemCount
                } catch {
                    failed += 1
                }
                processedItems += expectedItems
                publishProgress(0)
            }
            DispatchQueue.main.async {
                records = records.compactMap { record in
                    guard let usage = changed[record.id] else { return record }
                    return usage.totalBytes > 0 ? CleanerRecord(app: record.app, usage: usage) : nil
                }
                selected.removeAll()
                progressFraction = 1
                progressLabel = "Dọn xong"
                cleaning = false
                alert = .message(failed == 0 ? "Đã giải phóng khoảng \\(formatBytes(freed)) và xóa \\(removed) tệp." : "Đã giải phóng khoảng \\(formatBytes(freed)), xóa \\(removed) tệp. Có \\(failed) mục không xử lý được.")
            }
        }
    }
    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func makeAlert(_ alert: CleanerAlert) -> Alert {
        switch alert {
        case .confirmation:
            return Alert(
                title: Text("Xác nhận dọn dữ liệu tạm"),
                message: Text("Sẽ xóa cache và tệp tạm trong Library/Caches và tmp của \(selected.count) ứng dụng (ước tính \(formatBytes(selectedBytes))). Dữ liệu ứng dụng khác được giữ nguyên."),
                primaryButton: .destructive(Text("Xóa dữ liệu tạm"), action: cleanSelected),
                secondaryButton: .cancel(Text("Hủy"))
            )
        case .message(let text):
            return Alert(title: Text("Dọn dẹp"), message: Text(text), dismissButton: .default(Text("OK")))
        }
    }

    private func operatingSystemBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum CleanerAlert: Identifiable {
    case confirmation
    case message(String)
    var id: String {
        switch self {
        case .confirmation: return "confirm"
        case .message(let text): return text
        }
    }
}








