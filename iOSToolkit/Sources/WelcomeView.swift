import SwiftUI

/// Màn chào mừng: giới thiệu nhanh từng công cụ + lưu ý riêng của từng công cụ (nếu có).
/// Dấu X trên góc để đóng ngay, nút "Tiếp tục" ở dưới cùng để vào dùng app — cả hai đều
/// đánh dấu đã xem, nên lần sau mở app sẽ không hiện lại (có thể xem lại qua nút (i) ở màn chính).
struct WelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { onContinue() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Đóng")
            }
            .padding([.horizontal, .top], 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chào mừng tới iOS Toolkit")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Bộ công cụ gộp các việc hay làm với IPA/chứng chỉ vào một app. Dưới đây là các công cụ hiện có và vài lưu ý trước khi dùng.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Tool.catalog.filter(\.ready)) { tool in
                            toolCard(tool)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Lưu ý chung", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Các bản build được build tự động, chưa được kiểm thử tay trên thiết bị thật trước khi gửi tới bạn. Nên tự sao lưu IPA/chứng chỉ gốc trước khi thử, và báo lại nếu gặp lỗi.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            Button { onContinue() } label: {
                Text("Tiếp tục")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func toolCard(_ tool: Tool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tool.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(tool.color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(tool.subtitle).font(.footnote).foregroundStyle(.secondary)
                if let caution = tool.caution {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                        Text(caution).font(.caption)
                    }
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.4)))
    }
}
