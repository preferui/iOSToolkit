import SwiftUI
import UniformTypeIdentifiers

private enum AppleMusicImportPurpose {
    case pairing
    case audio
}

struct AppleMusicInjectionView: View {
    @ObservedObject private var device = DeviceManager.shared
    @State private var importPurpose: AppleMusicImportPurpose?
    @State private var isWorking = false
    @State private var status = "Nhập pairing file, bật LocalDevVPN rồi kết nối iPhone."
    @State private var progress = ""
    @State private var alertMessage: String?

    private var audioTypes: [UTType] {
        ["mp3", "m4a", "aac", "flac", "wav", "alac", "aiff"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    private var isImporterPresented: Binding<Bool> {
        Binding(
            get: { importPurpose != nil },
            set: { if !$0 { importPurpose = nil } }
        )
    }

    private var allowedImportTypes: [UTType] {
        importPurpose == .audio ? audioTypes : [.propertyList, .data]
    }

    var body: some View {
        List {
            Section("Thiết bị") {
                LabeledContent("Kết nối", value: device.connectionStatus)
                LabeledContent("Pairing", value: device.hasValidExpectedPairingFile ? "Đã nhập" : "Chưa có")

                Button {
                    importPurpose = .pairing
                } label: {
                    Label("Chọn pairing file", systemImage: "doc.badge.plus")
                }
                .disabled(isWorking)

                Button {
                    device.startHeartbeat(forceReconnect: true) { success in
                        DispatchQueue.main.async {
                            status = success
                                ? "Đã kết nối. Bạn có thể chọn nhạc."
                                : "Không kết nối được. Kiểm tra LocalDevVPN và pairing file."
                        }
                    }
                } label: {
                    Label("Kết nối lại thiết bị", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isWorking || !device.hasValidExpectedPairingFile)
            }

            Section("Thêm nhạc vào Apple Music") {
                Button {
                    importPurpose = .audio
                } label: {
                    Label("Chọn tệp nhạc", systemImage: "music.note")
                }
                .disabled(isWorking || !device.heartbeatReady)

                if isWorking {
                    ProgressView()
                    Text(progress.isEmpty ? "Đang xử lý…" : progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Hỗ trợ MP3, M4A, AAC, FLAC và WAV. Chỉ cần bật LocalDevVPN trước khi kết nối; VPN không tự chọn pairing file. Hãy sao lưu thư viện Apple Music trước khi ghi dữ liệu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple Music")
        // Keep one fileImporter modifier: stacking two importers on the same
        // view can prevent the second document picker from being presented.
        .fileImporter(
            isPresented: isImporterPresented,
            allowedContentTypes: allowedImportTypes,
            allowsMultipleSelection: importPurpose == .audio,
            onCompletion: handleImport
        )
        .alert("Apple Music", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("Đóng", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            device.refreshExpectedPairingFileState()
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let purpose = importPurpose
        importPurpose = nil

        switch purpose {
        case .pairing:
            importPairing(result)
        case .audio:
            importSongs(result)
        case .none:
            break
        }
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            // Copy into the app container while the security-scoped URL is valid.
            let folder = URL.documentsDirectory.appendingPathComponent("Pairing", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("pairing_file.plist")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            try device.importPairingFile(from: destination)
            device.refreshExpectedPairingFileState()
            status = "Đã nhập pairing file. LocalDevVPN đang bật thì hãy nhấn Kết nối lại thiết bị."
        } catch {
            alertMessage = "Không thể nhập pairing file: \(error.localizedDescription)"
        }
    }

    private func importSongs(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isWorking = true
            progress = "Đang đọc metadata…"
            status = ""

            Task {
                do {
                    let staging = URL.documentsDirectory.appendingPathComponent("AppleMusicImports", isDirectory: true)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    var songs: [SongMetadata] = []

                    for source in urls {
                        let scoped = source.startAccessingSecurityScopedResource()
                        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
                        let destination = staging.appendingPathComponent(UUID().uuidString + "." + ext)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                        songs.append(try await SongMetadata.fromURL(destination))
                    }

                    await MainActor.run { progress = "Đang chép nhạc vào thiết bị…" }
                    device.injectSongs(songs: songs, progress: { message in
                        DispatchQueue.main.async { progress = message }
                    }, completion: { success in
                        DispatchQueue.main.async {
                            isWorking = false
                            status = success
                                ? "Đã hoàn tất thêm nhạc. Mở Apple Music để kiểm tra."
                                : "Không thể thêm nhạc. Kiểm tra kết nối và nhật ký chẩn đoán."
                        }
                    })
                } catch {
                    await MainActor.run {
                        isWorking = false
                        alertMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
