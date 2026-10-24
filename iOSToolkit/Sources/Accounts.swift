import ApplePackage
import Foundation
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    @Published private(set) var accounts: [Account] = []
    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iOSToolkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("accounts.json")
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Account].self, from: data) { accounts = list }
    }

    /// Mã thiết bị phải cố định cho mọi yêu cầu (nếu đổi, tài khoản có thể bị Apple khoá).
    func prepareDevice() {
        let key = "ioskit.deviceID"
        var id = UserDefaults.standard.string(forKey: key) ?? ""
        let valid = id.count == 12 && id.allSatisfy { $0.isHexDigit } && !["000000000000", "FFFFFFFFFFFF", "020000000000"].contains(id.uppercased())
        if !valid {
            repeat { id = DeviceIdentifier.random() } while ["000000000000", "FFFFFFFFFFFF", "020000000000"].contains(id)
            UserDefaults.standard.set(id, forKey: key)
        }
        Configuration.deviceIdentifier = id.uppercased()
    }

    func account(_ email: String) -> Account? { accounts.first { $0.email == email } }

    func save(_ a: Account) {
        accounts = (accounts.filter { $0.email != a.email } + [a]).sorted { $0.email < $1.email }
        persist()
    }

    func remove(_ email: String) {
        accounts.removeAll { $0.email == email }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) { try? data.write(to: file, options: [.atomic, .completeFileProtection]) }
    }
}

struct AccountsView: View {
    @ObservedObject var store = AccountStore.shared

    var body: some View {
        List {
            Section {
                ForEach(store.accounts, id: \.email) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.email).font(.system(size: 16, weight: .semibold))
                        Text("\(a.firstName) \(a.lastName) · vùng \(Configuration.countryCode(for: a.store) ?? a.store)").font(.footnote).foregroundColor(.secondary)
                    }
                }
                .onDelete { idx in idx.map { store.accounts[$0].email }.forEach { store.remove($0) } }
                NavigationLink { AddAccountView() } label: { Label("Thêm tài khoản", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Tài khoản và mật khẩu chỉ lưu trên máy này (dùng để làm mới phiên đăng nhập). Nên dùng Apple ID phụ, không dùng tài khoản chính.")
            }
        }
        .navigationTitle("Tài khoản")
    }
}

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var showPw = false
    @State private var code = ""
    @State private var codeRequired = false
    @State private var session: ApplePackage.Authenticator?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Apple ID") {
                TextField("Email", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).textContentType(.emailAddress)
                HStack {
                    if showPw { TextField("Mật khẩu", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { SecureField("Mật khẩu", text: $password) }
                    Button { showPw.toggle() } label: { Image(systemName: showPw ? "eye.slash" : "eye").foregroundColor(.secondary) }.buttonStyle(.plain)
                }
            }
            if codeRequired {
                Section {
                    TextField("Mã xác minh 6 số", text: $code).keyboardType(.numberPad)
                } header: { Text("Mã 2FA") } footer: { Text("Apple đã gửi mã tới thiết bị khác của bạn. Nhập mã rồi bấm Đăng nhập lại.") }
            }
            Section {
                NavigationLink { DiagView() } label: { Label("Xem nhật ký", systemImage: "doc.text.magnifyingglass") }
                Button {
                    Task { await login() }
                } label: {
                    HStack { Text(busy ? "Đang đăng nhập…" : "Đăng nhập"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
            } footer: {
                if let error { Text(error).foregroundColor(.red) }
            }
        }
        .navigationTitle("Thêm tài khoản")
        .onChange(of: email) { _ in reset() }
        .onChange(of: password) { _ in reset() }
    }

    private func reset() { session = nil; codeRequired = false; code = ""; error = nil }

    private func login() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let s: ApplePackage.Authenticator
            if let session { s = session } else {
                Diag.log("đăng nhập: tạo phiên SAP…")
                s = try await ApplePackage.Authenticator(); session = s
                Diag.log("đăng nhập: phiên SAP sẵn sàng")
            }
            Diag.log("đăng nhập: gửi yêu cầu xác thực…")
            let acc = try await s.authenticate(email: email.trimmingCharacters(in: .whitespaces), password: password, code: code.trimmingCharacters(in: .whitespaces))
            Diag.log("đăng nhập: thành công")
            AccountStore.shared.save(acc)
            dismiss()
        } catch {
            Diag.log("đăng nhập: lỗi \(error)")
            if case ApplePackage.AuthenticationError.verificationCodeRequired = error { codeRequired = true; self.error = "Cần nhập mã xác minh 2FA." }
            else { self.error = error.localizedDescription }
        }
    }
}
