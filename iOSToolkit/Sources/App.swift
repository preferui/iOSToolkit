import ApplePackage
import SwiftUI

@main
struct ToolkitApp: App {
    init() { Diag.start(); AccountStore.shared.prepareDevice(); Diag.log("thiết bị: \(Configuration.deviceIdentifier)") }
    var body: some Scene { WindowGroup { RootView() } }
}

struct Tool: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let ready: Bool
    var kind: Int = 0
}

struct RootView: View {
    private let tools: [Tool] = [
        Tool(title: "Tải IPA từ App Store", subtitle: "Tải app theo ID bằng Apple ID của bạn, kể cả app đã bị gỡ nếu tài khoản từng nhận", icon: "arrow.down.app.fill", color: .blue, ready: true),
        Tool(title: "Đổi mật khẩu P12", subtitle: "Chọn gói zip chứng chỉ, nhập mật khẩu cũ và mới, ghi đè thẳng vào gói zip", icon: "key.fill", color: .green, ready: true, kind: 1),
        Tool(title: "Dọn dẹp ứng dụng", subtitle: "Quét cache và tệp tạm của từng ứng dụng", icon: "sparkles", color: .cyan, ready: true, kind: 2),
        Tool(title: "Ký IPA", subtitle: "Sắp có", icon: "signature", color: .purple, ready: false),
        Tool(title: "Công cụ khác", subtitle: "Sắp có", icon: "wrench.and.screwdriver.fill", color: .orange, ready: false),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tools) { tool in
                        if tool.ready {
                            NavigationLink {
                                if tool.kind == 1 { P12ToolView() }
                                else if tool.kind == 2 { CleanerToolView() }
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
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { NavigationLink { DiagView() } label: { Image(systemName: "doc.text.magnifyingglass") } } }
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
