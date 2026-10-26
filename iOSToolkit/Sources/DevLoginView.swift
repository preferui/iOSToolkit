//
//  DevLoginView.swift
//  iOSToolkit
//
//  Màn hình đăng nhập Apple ID kiểu "Developer" (GrandSlam) — bước đầu tiên của
//  tính năng tự gia hạn iOS Toolkit. Màn hình này DỪNG LẠI ở việc xác nhận đăng
//  nhập thành công; phần xin chứng chỉ + tự ký lại app sẽ làm ở bước sau.
//

import SwiftUI

private enum DevLoginStage: Equatable {
    case idle
    case working(String)
    case twoFactorChoose(DevTwoFactorContext, phoneIDs: [String])
    case twoFactorEnterCode(DevTwoFactorContext, channel: DevTwoFactorChannel)
    case success(DevAppleSession)
    case error(String)

    static func == (lhs: DevLoginStage, rhs: DevLoginStage) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.working(let a), .working(let b)): return a == b
        case (.success, .success): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

struct DevLoginView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var stage: DevLoginStage = .idle
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case appleID, password, code }

    var body: some View {
        Form {
            Section {
                Text("Đăng nhập bằng Apple ID thường (không cần tài khoản Developer trả phí, không cần chứng chỉ doanh nghiệp). Dùng để sau này tự gia hạn iOS Toolkit giống cách SideStore làm.")
                    .font(.footnote).foregroundColor(.secondary)
            }

            switch stage {
            case .idle, .error:
                credentialsSection
                if case .error(let msg) = stage {
                    Section { Text(msg).foregroundColor(.red).font(.footnote) }
                    Section {
                        Button("Đặt lại dữ liệu anisette rồi thử lại") { resetAnisetteAndRetry() }
                    } footer: {
                        Text("Dùng nếu đăng nhập liên tục báo lỗi không rõ nguyên nhân từ Apple — xoá định danh thiết bị ảo cũ (không cần tải lại thư viện).")
                    }
                }
                Section {
                    Button("Đăng nhập") { startLogin() }
                        .disabled(appleID.isEmpty || password.isEmpty)
                }

            case .working(let msg):
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(msg).foregroundColor(.secondary)
                    }
                }

            case .twoFactorChoose(_, let phoneIDs):
                Section("Cần xác thực 2 lớp") {
                    Button("Gửi mã tới thiết bị tin cậy") { requestCode(channel: .trustedDevice) }
                    ForEach(phoneIDs, id: \.self) { pid in
                        Button("Gửi mã SMS (số #\(pid))") { requestCode(channel: .sms(phoneID: pid)) }
                    }
                }

            case .twoFactorEnterCode(_, let channel):
                Section(channelLabel(channel)) {
                    TextField("Nhập mã 6 số", text: $code)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .code)
                    Button("Xác minh") { verifyCode(channel: channel) }
                        .disabled(code.count < 4)
                }

            case .success(let session):
                Section("Đăng nhập thành công") {
                    LabeledContent("Apple ID", value: session.appleID)
                    LabeledContent("DSID", value: maskedDSID(session.dsid))
                    Text("Đã lấy được token cho dịch vụ Xcode. Bước tiếp theo (xin chứng chỉ + tự ký lại app) sẽ làm sau khi bạn xác nhận phần này chạy ổn.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section {
                    Button("Đăng nhập tài khoản khác", role: .destructive) { reset() }
                }
            }
        }
        .navigationTitle("Đăng nhập Apple ID (Dev)")
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Xong") { focusedField = nil }
            }
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Apple ID (email)", text: $appleID)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .appleID)
            SecureField("Mật khẩu", text: $password)
                .focused($focusedField, equals: .password)
        }
    }

    private func channelLabel(_ c: DevTwoFactorChannel) -> String {
        switch c {
        case .trustedDevice: return "Mã gửi tới thiết bị tin cậy"
        case .sms: return "Mã gửi qua SMS"
        }
    }

    private func maskedDSID(_ dsid: String) -> String {
        guard dsid.count > 4 else { return dsid }
        return String(repeating: "•", count: max(0, dsid.count - 4)) + dsid.suffix(4)
    }

    private func reset() {
        appleID = ""; password = ""; code = ""
        stage = .idle
    }

    private func startLogin() {
        focusedField = nil
        let id = appleID, pw = password
        stage = .working("Đang chuẩn bị anisette…")
        Task {
            do {
                let anisette = try await loadAnisetteWithProgress()
                await setStage(.working("Đang đăng nhập với Apple…"))
                let outcome = try await DevGSAAuth.performSRPLogin(appleID: id, password: pw, anisetteHeaders: anisette)
                switch outcome {
                case .success(let session):
                    Diag.log("DevLogin: đăng nhập thành công cho \(session.appleID)")
                    await setStage(.success(session))
                case .twoFactorRequired(let ctx):
                    Diag.log("DevLogin: tài khoản \(id) cần xác thực 2 lớp")
                    await setStage(.twoFactorChoose(ctx, phoneIDs: ctx.trustedPhoneIDs))
                }
            } catch {
                Diag.log("DevLogin lỗi: \(error.localizedDescription)")
                await setStage(.error(error.localizedDescription))
            }
        }
    }

    private func resetAnisetteAndRetry() {
        Task {
            await DevAnisette.shared.resetProvisioning()
            Diag.log("DevLogin: đã đặt lại dữ liệu anisette, thử đăng nhập lại")
            startLogin()
        }
    }

    private func loadAnisetteWithProgress() async throws -> [String: String] {
        try await DevAnisette.shared.fetchHeaders { msg in
            Task { await self.setStage(.working(msg)) }
        }
    }

    private func requestCode(channel: DevTwoFactorChannel) {
        guard case .twoFactorChoose(let ctx, _) = stage else { return }
        stage = .working("Đang gửi mã…")
        Task {
            do {
                try await DevGSAAuth.requestTwoFactorCode(channel: channel, context: ctx)
                await setStage(.twoFactorEnterCode(ctx, channel: channel))
            } catch {
                await setStage(.error(error.localizedDescription))
            }
        }
    }

    private func verifyCode(channel: DevTwoFactorChannel) {
        guard case .twoFactorEnterCode(let ctx, _) = stage else { return }
        focusedField = nil
        let enteredCode = code
        stage = .working("Đang xác minh mã…")
        Task {
            do {
                try await DevGSAAuth.submitTwoFactorCode(enteredCode, channel: channel, context: ctx)
                await setStage(.working("Đã xác minh — đang đăng nhập lại…"))
                let session = try await DevGSAAuth.retryLoginAfterTwoFactor(context: ctx)
                Diag.log("DevLogin: đăng nhập thành công sau 2FA cho \(session.appleID)")
                await setStage(.success(session))
            } catch {
                Diag.log("DevLogin 2FA lỗi: \(error.localizedDescription)")
                await setStage(.error(error.localizedDescription))
            }
        }
    }

    @MainActor
    private func setStage(_ s: DevLoginStage) {
        stage = s
    }
}
