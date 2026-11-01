import SwiftUI
import UniformTypeIdentifiers

/// Bước nền tảng của tính năng "Đồng bộ thiết bị" (cảm hứng từ ByeTunes): nhập tệp pairing và
/// thử bắt tay/giữ sống kết nối tới chính thiết bị qua idevice-ffi. CHƯA làm phần tiêm nhạc vào
/// thư viện Apple Music — đó là bước kế tiếp, sau khi bước kết nối này chạy ổn trên máy thật.
struct DeviceSyncView: View {
    @ObservedObject private var manager = DeviceSyncManager.shared
    @State private var message: String?
    @State private var isError = false
    @State private var showGuide = false
    @State private var afcTesting = false
    @State private var afcResult: String?
    @State private var afcResultIsError = false
    @State private var libraryLoading = false
    @State private var libraryResult: String?
    @State private var libraryResultIsError = false
    @State private var debugLoading = false
    @State private var debugResult: String?
    @State private var debugResultIsError = false

    var body: some View {
        Form {
            Section {
                Text("Tính năng thử nghiệm (Beta). Để app tự nói chuyện được với các dịch vụ nội bộ của chính thiết bị (giống máy tính đã ghép cặp), bạn cần CẢ HAI thứ sau — thiếu một trong hai sẽ không kết nối được:")
                    .font(.footnote)
                Button { showGuide = true } label: {
                    Label("Xem hướng dẫn chuẩn bị", systemImage: "questionmark.circle")
                }
            }

            Section {
                HStack {
                    Image(systemName: manager.hasValidExpectedPairingFile ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(manager.hasValidExpectedPairingFile ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.expectedPairingFileTitle)
                        Text(manager.hasValidExpectedPairingFile ? "Đã nhập, định dạng hợp lệ" : "Chưa có / không hợp lệ")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { pickPairingFile() } label: {
                    Label("Nhập \(manager.expectedPairingFileTitle)…", systemImage: "doc.badge.plus")
                }
            } header: {
                Text("Tệp pairing")
            } footer: {
                Text("Xuất bằng idevice_pair từ máy tính (xem hướng dẫn), rồi AirDrop/lưu vào iPhone và nhập vào đây.")
            }

            Section {
                HStack {
                    statusDot
                    Text(manager.connectionStatus)
                    Spacer()
                    if manager.connectionStatus == "Đang kết nối…" { ProgressView() }
                }
                if manager.heartbeatReady {
                    Button(role: .destructive) { manager.stopHeartbeat() } label: {
                        Label("Ngắt kết nối", systemImage: "bolt.slash")
                    }
                } else {
                    Button { connect() } label: {
                        Label("Kết nối", systemImage: "bolt.fill")
                    }
                    .disabled(!manager.hasValidExpectedPairingFile || manager.connectionStatus == "Đang kết nối…")
                }
            } header: {
                Text("Kết nối")
            } footer: {
                Text("App sẽ tự thử kết nối lại khi app đang mở và tệp pairing hợp lệ, không cần bấm lại mỗi lần.")
            }

            if manager.heartbeatReady {
                Section {
                    NavigationLink {
                        DeviceSyncMusicView()
                    } label: {
                        Label("Thêm / dọn nhạc trong thư viện", systemImage: "music.note.list")
                    }
                } footer: {
                    Text("Thêm bài hát từ tệp nhạc trong máy vào thư viện Apple Music của thiết bị, hoặc xoá bài hát đã có. Nên dùng thử tính năng \"Xem tóm tắt thư viện nhạc\" bên dưới trước để chắc chắn đọc thư viện ổn, trước khi ghi.")
                }

                Section {
                    Button { runAfcTest() } label: {
                        Label(afcTesting ? "Đang kiểm tra…" : "Kiểm tra đọc/ghi AFC", systemImage: "externaldrive.badge.checkmark")
                    }
                    .disabled(afcTesting)
                    if let afcResult {
                        Text(afcResult).font(.footnote).foregroundStyle(afcResultIsError ? .red : .green).textSelection(.enabled)
                    }
                } header: {
                    Text("Kiểm tra sâu hơn")
                } footer: {
                    Text("Ghi thử 1 tệp nhỏ vào vùng media của thiết bị rồi đọc lại và xoá ngay — không đụng tới thư viện nhạc thật. Bước này cần làm trước khi tiến tới phần tiêm nhạc vào Apple Music.")
                }

                Section {
                    Button { runLibrarySummary() } label: {
                        Label(libraryLoading ? "Đang đọc thư viện…" : "Xem tóm tắt thư viện nhạc", systemImage: "music.note.list")
                    }
                    .disabled(libraryLoading)
                    if let libraryResult {
                        Text(libraryResult).font(.footnote).foregroundStyle(libraryResultIsError ? .red : .green).textSelection(.enabled)
                    }
                } header: {
                    Text("Thư viện Apple Music")
                } footer: {
                    Text("Chỉ ĐỌC: tải tạm database thư viện nhạc về để đếm số bài hát/playlist rồi xoá bản tải tạm ngay, không ghi gì lên thiết bị. Đây là bước xác nhận trước khi làm tính năng thêm nhạc trực tiếp vào Apple Music.")
                }

                Section {
                    Button { runRecentItemsDebug() } label: {
                        Label(debugLoading ? "Đang đọc…" : "Xem chi tiết 5 bài mới sửa gần đây (debug)", systemImage: "ladybug")
                    }
                    .disabled(debugLoading)
                    if let debugResult {
                        Text(debugResult).font(.system(.footnote, design: .monospaced)).foregroundStyle(debugResultIsError ? .red : .primary).textSelection(.enabled)
                    }
                } header: {
                    Text("Chẩn đoán")
                } footer: {
                    Text("Chỉ ĐỌC: in ra nguyên văn các cột title/location/media_kind… của vài bài mới sửa gần đây trong database, để kiểm tra khi app Nhạc hiển thị bất thường (ví dụ tên bài trống).")
                }
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(isError ? .red : .secondary).textSelection(.enabled) }
            }

            Section {
                NavigationLink { DiagView() } label: { Label("Xem nhật ký", systemImage: "doc.text.magnifyingglass") }
            }
        }
        .navigationTitle("Đồng bộ thiết bị")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGuide) { guideSheet }
    }

    private var statusDot: some View {
        Circle()
            .fill(manager.heartbeatReady ? Color.green : (manager.connectionStatus == "Đang kết nối…" ? Color.orange : Color.secondary))
            .frame(width: 10, height: 10)
    }

    private func pickPairingFile() {
        DocPicker.present(types: [.data, .item], asCopy: true) { urls in
            guard let url = urls.first else { return }
            do {
                try manager.importPairingFile(from: url)
                isError = false
                message = manager.hasValidExpectedPairingFile ? "Đã nhập \(manager.expectedPairingFileTitle)." : "Đã sao chép tệp nhưng định dạng không hợp lệ."
                isError = !manager.hasValidExpectedPairingFile
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }

    private func connect() {
        message = nil
        manager.startHeartbeat(forceReconnect: true) { success in
            DispatchQueue.main.async {
                if !success {
                    isError = true
                    message = "Không kết nối được. Kiểm tra lại: đã bật app VPN cục bộ (ví dụ LocalDevVPN) và tệp pairing còn đúng với thiết bị này chưa."
                }
            }
        }
    }

    private func runAfcTest() {
        afcTesting = true
        afcResult = nil
        manager.runAfcRoundTripTest { result in
            afcTesting = false
            switch result {
            case .success(let text):
                afcResultIsError = false
                afcResult = text
            case .failure(let error):
                afcResultIsError = true
                afcResult = error.localizedDescription
            }
        }
    }

    private func runLibrarySummary() {
        libraryLoading = true
        libraryResult = nil
        manager.fetchLibrarySummary { result in
            libraryLoading = false
            switch result {
            case .success(let summary):
                libraryResultIsError = false
                libraryResult = "Số bài hát: \(summary.songCount) · Số playlist: \(summary.playlistCount) · Phiên bản schema: \(summary.iosSchemaUserVersion)"
            case .failure(let error):
                libraryResultIsError = true
                libraryResult = error.localizedDescription
            }
        }
    }

    private func runRecentItemsDebug() {
        debugLoading = true
        debugResult = nil
        manager.fetchRecentItemsDebug { result in
            debugLoading = false
            switch result {
            case .success(let text):
                debugResultIsError = false
                debugResult = text
            case .failure(let error):
                debugResultIsError = true
                debugResult = error.localizedDescription
            }
        }
    }

    private var guideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cần chuẩn bị trước").font(.title3.bold())
                    guideStep(number: 1, title: "App VPN cục bộ", body: "Cài một app kiểu LocalDevVPN (ví dụ trên App Store/AltStore) và để nó ở trạng thái Đã kết nối. App này tạo ra một địa chỉ mạng nội bộ để iOS Toolkit có thể tự \"nói chuyện\" với chính thiết bị, giống như đang cắm dây với một máy tính đã ghép cặp.")
                    guideStep(number: 2, title: "Xuất tệp pairing từ máy tính", body: "Trên máy tính (Mac/PC), dùng công cụ idevice_pair (xem github.com/jkcoxson/idevice_pair) để ghép cặp với iPhone qua cáp và xuất ra một tệp pairing.")
                    guideStep(number: 3, title: "Chuyển tệp vào iPhone", body: "AirDrop hoặc lưu tệp đó vào iPhone, rồi dùng nút \"Nhập…\" ở trên để đưa vào iOS Toolkit.")
                    guideStep(number: 4, title: "Bấm Kết nối", body: "Nếu cả app VPN lẫn tệp pairing đều đúng, trạng thái sẽ chuyển sang \"Đã kết nối\". Nếu lỗi, mở mục \"Xem nhật ký\" để xem chi tiết.")
                    Text("Lưu ý: đây là tính năng nền tảng cho việc đồng bộ nhạc không cần máy tính (giống ByeTunes) — bản này mới làm xong phần kết nối, chưa có phần tiêm nhạc vào thư viện Apple Music.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Hướng dẫn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { showGuide = false } } }
        }
    }

    private func guideStep(number: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.headline).frame(width: 24, height: 24).background(Circle().fill(.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
