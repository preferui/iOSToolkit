import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum AppleMusicImportPurpose: String, Identifiable {
    case pairing
    case audio

    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        case .pairing:
            return [.data, .propertyList]
        case .audio:
            return ["mp3", "m4a", "aac", "flac", "wav", "alac", "aiff"]
                .compactMap { UTType(filenameExtension: $0) }
        }
    }

    var allowsMultipleSelection: Bool { self == .audio }
}

struct AppleMusicInjectionView: View {
    @ObservedObject private var device = DeviceManager.shared
    @State private var importPurpose: AppleMusicImportPurpose?
    @State private var isWorking = false
    @State private var status = "Nhập pairing file, bật LocalDevVPN rồi kết nối iPhone."
    @State private var progress = ""
    @State private var alertMessage: String?

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
                Text("Hỗ trợ MP3, M4A, AAC, FLAC và WAV. Bật LocalDevVPN trước khi kết nối. Hãy sao lưu thư viện Apple Music trước khi ghi dữ liệu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple Music")
        // Use the native UIKit document picker. On iOS 17, a state-driven
        // SwiftUI fileImporter attached to a List can fail to present.
        .fullScreenCover(item: $importPurpose) { purpose in
            AppleMusicDocumentPicker(purpose: purpose) { result in
                importPurpose = nil
                switch purpose {
                case .pairing:
                    importPairing(result)
                case .audio:
                    importSongs(result)
                }
            }
            .ignoresSafeArea()
        }
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

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            // The document picker returns a local copy (asCopy: true).
            // DeviceManager validates the selected pairing format before saving it.
            try device.importPairingFile(from: url)
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

private struct AppleMusicDocumentPicker: UIViewControllerRepresentable {
    let purpose: AppleMusicImportPurpose
    let completion: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: purpose.contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = purpose.allowsMultipleSelection
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Result<[URL], Error>) -> Void

        init(completion: @escaping (Result<[URL], Error>) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.success([]))
        }
    }
}
