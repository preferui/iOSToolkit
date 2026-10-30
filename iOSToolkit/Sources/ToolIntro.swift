import SwiftUI

/// Bọc quanh nội dung thật của một công cụ: mỗi lần mở công cụ, hiện màn giới thiệu + lưu ý
/// riêng của công cụ đó trước. Dấu X trên góc để trở ra danh sách, nút "Tiếp tục" ở dưới để
/// vào dùng công cụ thật (nội dung `content` chỉ được dựng khi đã bấm "Tiếp tục").
struct ToolIntroGate<Content: View>: View {
    let tool: Tool
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var entered = false

    var body: some View {
        if entered {
            content()
        } else {
            ToolIntroView(tool: tool, onCancel: { dismiss() }, onContinue: { entered = true })
                .navigationBarBackButtonHidden(true)
                .navigationBarHidden(true)
        }
    }
}

/// Màn giới thiệu của riêng một công cụ: tên, mô tả, lưu ý (nếu có).
struct ToolIntroView: View {
    let tool: Tool
    var onCancel: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Đóng")
            }
            .padding([.horizontal, .top], 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 14) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 72, height: 72)
                            .background(tool.color.gradient)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text(tool.title)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        Text(tool.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    if let caution = tool.caution {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Lưu ý", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text(caution)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Text("Các bản build chưa được tự kiểm tra tay trên thiết bị thật trước khi gửi tới bạn — nên tự sao lưu dữ liệu/chứng chỉ gốc trước khi thử.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            Button { onContinue() } label: {
                Text("Tiếp tục")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(tool.color)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
