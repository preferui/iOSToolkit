import SwiftUI
import UniformTypeIdentifiers

struct AppleMusicInjectionView: View {
    @ObservedObject private var device = DeviceManager.shared
    @State private var showingPairingImporter = false
    @State private var showingMusicImporter = false
    @State private var isWorking = false
    @State private var status = "Import a pairing file, connect LocalDevVPN, then choose audio files."
    @State private var progress = ""
    @State private var alertMessage: String?
    
    private var audioTypes: [UTType] {
        ["mp3", "m4a", "aac", "flac", "wav", "alac", "aiff"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        List {
            Section("Thiết bị") {
                LabeledContent("Kết nối", value: device.connectionStatus)
                LabeledContent("Pairing", value: device.hasValidExpectedPairingFile ? "Đã nhập" : "Chưa có")
                Button {
                    showingPairingImporter = true
                } label: {
                    Label("Nhập pairing file", systemImage: "link")
                }
                .disabled(isWorking)
                Button {
                    device.startHeartbeat(forceReconnect: true) { success in
                        DispatchQueue.main.async {
                            status = success
                                ? "Đã kết nối. Bạn có thể chọn nhạc."
                                : "Không kết nối được. Hãy bật LocalDevVPN và kiểm tra pairing file."
                        }
                    }
                } label: {
                    Label("Kết nối lại thiết bị", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isWorking || !device.hasValidExpectedPairingFile)
            }

            Section("Thêm nhạc vào Apple Music") {
                Button {
                    showingMusicImporter = true
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
                Text("Hỗ trợ MP3, M4A, AAC, FLAC và WAV. Cần LocalDevVPN đang kết nối cùng pairing file hợp lệ. Trước khi ghi thư viện, hãy sao lưu dữ liệu Apple Music.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple Music")
        .fileImporter(isPresented: $showingPairingImporter, allowedContentTypes: [.propertyList, .data], allowsMultipleSelection: false, onCompletion: importPairing)
        .fileImporter(isPresented: $showingMusicImporter, allowedContentTypes: audioTypes, allowsMultipleSelection: true, onCompletion: importSongs)
        .alert("Apple Music", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("Đóng", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            device.refreshExpectedPairingFileState()
        }
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            try device.importPairingFile(from: url)
            device.refreshExpectedPairingFileState()
            status = "Đã nhập pairing file. Hãy bật LocalDevVPN rồi kết nối thiết bị."
        } catch {
            alertMessage = error.localizedDescription
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
                        let destination = staging.appendingPathComponent(UUID().uuidString + "." + source.pathExtension.lowercased())
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
