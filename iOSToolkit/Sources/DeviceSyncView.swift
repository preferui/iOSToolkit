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
