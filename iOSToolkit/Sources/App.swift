import ApplePackage
import SwiftUI

@main
struct ToolkitApp: App {
    init() { Diag.start(); AccountStore.shared.prepareDevice(); Diag.log("thiết bị: \(Configuration.deviceIdentifier)") }
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct Tool: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let ready: Bool
    var kind: Int = 0
    /// Lưu ý/cảnh báo riêng cho công cụ này, hiện ở màn chào mừng. nil nếu không có gì đặc biệt.
    var caution: String? = nil

    static let catalog: [Tool] = [
        Tool(title: "Tải IPA từ App Store", subtitle: "Tải app theo ID bằng Apple ID của bạn, kể cả app đã bị gỡ nếu tài khoản từng nhận", icon: "arrow.down.app.fill", color: .blue, ready: true,
             caution: "Cần đăng nhập Apple ID thật của bạn để lấy IPA — chỉ dùng để tải app bạn đã sở hữu/được phép, không phải cách lách mua app trả phí."),
        Tool(title: "Đổi mật khẩu P12", subtitle: "Chọn gói zip chứng chỉ, nhập mật khẩu cũ và mới, ghi đè thẳng vào gói zip", icon: "key.fill", color: .green, ready: true, kind: 1,
             caution: "Thao tác ghi đè thẳng lên gói zip gốc — nên giữ thêm 1 bản sao lưu trước khi đổi."),
        Tool(title: "Nhân bản / Edit IPA", subtitle: "Đổi Bundle ID, tên, icon — tạo nhiều bản cài song song từ 1 IPA", icon: "rectangle.on.rectangle", color: .teal, ready: true, kind: 2),
        Tool(title: "Ký IPA", subtitle: "Ký IPA bằng chứng chỉ .p12 + .mobileprovision của bạn (dùng zsign)", icon: "signature", color: .purple, ready: true, kind: 3,
             caution: "Cần chứng chỉ .p12 + .mobileprovision còn hạn và khớp nhau. Chứng chỉ hết hạn/không khớp sẽ ký thất bại."),
        Tool(title: "Đồng bộ thiết bị (Beta)", subtitle: "Bước nền tảng: nhập pairing file + kết nối thẳng tới thiết bị, không qua máy tính", icon: "antenna.radiowaves.left.and.right", color: .pink, ready: true, kind: 4,
             caution: "Thử nghiệm (Beta). Cần cài thêm 1 app VPN cục bộ (kiểu LocalDevVPN) đang chạy + pairing file xuất từ máy tính. Chưa được kiểm thử đầy đủ trên thiết bị thật."),
        Tool(title: "Công cụ khác", subtitle: "Sắp có", icon: "wrench.and.screwdriver.fill", color: .orange, ready: false),
    ]
}

struct RootView: View {
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "ioskit.welcome.seen.v1")
    private let tools = Tool.catalog

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tools) { tool in
                        if tool.ready {
                            NavigationLink {
                                if tool.kind == 1 { P12ToolView() }
                                else if tool.kind == 2 { IPACloneToolView() }
                                else if tool.kind == 3 { SignToolView() }
                                else if tool.kind == 4 { DeviceSyncView() }
                                else { AppStoreToolView() }
                            } label: { row(tool) }
                        } else {
                            row(tool).opacity(0.5)
                        }
                    }
                } footer: {
                    Text("iOS Toolkit — bộ công cụ cho iOS. Thêm chức năng mới theo thời gian.")
                }
            }
            .navigationTitle("iOS Toolkit")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showWelcome = true } label: { Image(systemName: "info.circle") }
                    NavigationLink { DiagView() } label: { Image(systemName: "doc.text.magnifyingglass") }
                }
            }
        }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                UserDefaults.standard.set(true, forKey: "ioskit.welcome.seen.v1")
                showWelcome = false
            }
        }
    }

    private func row(_ t: Tool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: t.icon).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                .frame(width: 44, height: 44).background(t.color.gradient).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(t.subtitle).font(.footnote).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}


// Trigger build after iOS deployment compatibility fix.
