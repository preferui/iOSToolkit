import SwiftUI
import UniformTypeIdentifiers

/// Giao diện "Thêm nhạc" + "Dọn nhạc" — phần ghi trực tiếp vào thư viện Apple Music của thiết bị,
/// lấy cảm hứng từ ByeTunes nhưng CHỈ thao tác trên file nhạc của chính người dùng (không có phần
/// tải nhạc từ backend nào). Vào từ màn "Đồng bộ thiết bị" sau khi đã kết nối thành công.
struct DeviceSyncMusicView: View {
    @ObservedObject private var manager = DeviceSyncManager.shared

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DeviceSyncAddSongView()
                } label: {
                    Label("Thêm nhạc vào thư viện", systemImage: "plus.circle")
                }
                NavigationLink {
                    DeviceSyncCleanupView()
                } label: {
                    Label("Dọn / xoá nhạc khỏi thư viện", systemImage: "trash")
                }
            } footer: {
                Text("Thao tác ghi trực tiếp lên database thư viện Apple Music thật trên máy — luôn tải bản sao lưu tạm trước khi sửa và tráo an toàn (nếu lỗi giữa chừng sẽ tự phục hồi bản cũ). Dù vậy, nên sao lưu máy (iTunes/Finder hoặc iCloud) trước khi dùng thường xuyên.")
            }
        }
        .navigationTitle("Thư viện nhạc")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Thêm nhạc

struct DeviceSyncAddSongView: View {
    @ObservedObject private var manager = DeviceSyncManager.shared
    @State private var pickedURL: URL?
    @State private var metadata: LocalSongMetadata?
    @State private var readingMetadata = false
    @State private var adding = false
    @State private var progressText: String?
    @State private var result: String?
    @State private var resultIsError = false

    var body: some View {
        Form {
            Section {
                Button { pickFile() } label: {
                    Label(pickedURL?.lastPathComponent ?? "Chọn tệp nhạc…", systemImage: "music.note")
                }
                .disabled(adding)
            } footer: {
                Text("Hỗ trợ mp3, m4a, flac, wav, alac… Tiêu đề/ca sĩ/album/ảnh bìa được đọc từ tag có sẵn trong chính tệp nhạc (không tra cứu ở đâu khác).")
            }

            if readingMetadata {
                Section { HStack { ProgressView(); Text("Đang đọc thông tin bài hát…") } }
            }

            if let metadata {
                Section("Thông tin đọc được") {
                    LabeledContent("Tiêu đề", value: metadata.title)
                    LabeledContent("Ca sĩ", value: metadata.artist)
                    LabeledContent("Album", value: metadata.album)
                    LabeledContent("Thể loại", value: metadata.genre)
                    if metadata.durationMs > 0 {
                        LabeledContent("Thời lượng", value: formatDuration(metadata.durationMs))
                    }
                    if metadata.artworkData != nil {
                        Label("Có ảnh bìa trong tệp (CHƯA được thêm vào thư viện ở bản này)", systemImage: "photo")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button { addSong() } label: {
                        Label(adding ? (progressText ?? "Đang thêm…") : "Thêm vào thư viện", systemImage: "square.and.arrow.down")
                    }
                    .disabled(adding)
                } footer: {
                    Text("Nếu thư viện đã có bài trùng tên + ca sĩ + album, sẽ báo trùng và không thêm lại.")
                }
            }

            if let result {
                Section { Text(result).foregroundStyle(resultIsError ? .red : .green).textSelection(.enabled) }
            }
        }
        .navigationTitle("Thêm nhạc")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pickFile() {
        DocPicker.present(types: [.audio], asCopy: true) { urls in
            guard let url = urls.first else { return }
            pickedURL = url
            metadata = nil
            result = nil
            readingMetadata = true
            Task {
                do {
                    let m = try await LocalSongMetadataReader.read(from: url)
                    await MainActor.run { metadata = m; readingMetadata = false }
                } catch {
                    await MainActor.run {
                        readingMetadata = false
                        resultIsError = true
                        result = error.localizedDescription
                    }
                }
            }
        }
    }

    private func addSong() {
        guard let metadata else { return }
        adding = true
        result = nil
        progressText = "Đang bắt đầu…"
        manager.addSong(from: metadata, onProgress: { progressText = $0 }) { outcome in
            adding = false
            switch outcome {
            case .success:
                resultIsError = false
                result = "Đã thêm \"\(metadata.title)\" vào thư viện. Nếu app Nhạc chưa thấy bài mới ngay, hãy mở lại app Nhạc hoặc khởi động lại iPhone."
                self.metadata = nil
                self.pickedURL = nil
            case .failure(let error):
                resultIsError = true
                result = error.localizedDescription
            }
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Dọn / xoá nhạc

struct DeviceSyncCleanupView: View {
    @ObservedObject private var manager = DeviceSyncManager.shared
    @State private var songs: [DeviceLibrarySong] = []
    @State private var loading = false
    @State private var error: String?
    @State private var deletingPid: Int64?
    @State private var pendingDelete: DeviceLibrarySong?
    @State private var lastMessage: String?

    var body: some View {
        List {
            if loading {
                Section { HStack { ProgressView(); Text("Đang tải danh sách bài hát…") } }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            if let lastMessage {
                Section { Text(lastMessage).foregroundStyle(.green) }
            }
            Section {
                ForEach(songs) { song in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(song.title)
                            Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if deletingPid == song.itemPid {
                            ProgressView()
                        } else {
                            Button(role: .destructive) { pendingDelete = song } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(deletingPid != nil)
                        }
                    }
                }
            } header: {
                Text("\(songs.count) bài hát trong thư viện")
            } footer: {
                Text("Xoá sẽ gỡ cả tệp âm thanh trên thiết bị lẫn hàng database liên quan — không thể hoàn tác.")
            }
        }
        .navigationTitle("Dọn nhạc")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.disabled(loading)
            }
        }
        .onAppear { if songs.isEmpty { load() } }
        .alert("Xoá bài hát?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Huỷ", role: .cancel) { pendingDelete = nil }
            Button("Xoá", role: .destructive) {
                if let song = pendingDelete { delete(song) }
                pendingDelete = nil
            }
        } message: {
            if let pendingDelete {
                Text("Xoá \"\(pendingDelete.title)\" khỏi thư viện và khỏi thiết bị. Không thể hoàn tác.")
            }
        }
    }

    private func load() {
        loading = true
        error = nil
        manager.listLibrarySongs { result in
            loading = false
            switch result {
            case .success(let list): songs = list
            case .failure(let err): error = err.localizedDescription
            }
        }
    }

    private func delete(_ song: DeviceLibrarySong) {
        deletingPid = song.itemPid
        lastMessage = nil
        manager.deleteSong(song) { result in
            deletingPid = nil
            switch result {
            case .success:
                songs.removeAll { $0.itemPid == song.itemPid }
                lastMessage = "Đã xoá \"\(song.title)\"."
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }
}
