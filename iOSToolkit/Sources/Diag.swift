import Darwin
import Foundation
import SwiftUI

/// Ghi nhật ký + bắt lỗi văng app vào Documents/diag.log (xem trong app hoặc app Tệp).
enum Diag {
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag.log")
    }

    static func start() {
        // Giữ lại tối đa ~200KB cuối của lần chạy trước.
        if let data = try? Data(contentsOf: url), data.count > 200_000 { try? data.suffix(100_000).write(to: url) }
        freopen(url.path, "a+", stderr)
        setvbuf(stderr, nil, _IONBF, 0)
        log("=== khởi động \(Date()) · iOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===")
        for sig in [SIGILL, SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGFPE] {
            signal(sig) { s in
                let head = "\n[VĂNG APP] tín hiệu \(s)\n"
                _ = head.withCString { write(2, $0, strlen($0)) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
                let n = backtrace(&frames, 48)
                backtrace_symbols_fd(&frames, n, 2)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        NSSetUncaughtExceptionHandler { e in
            fputs("\n[NGOẠI LỆ] \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))\n", stderr)
        }
    }

    static func log(_ s: String) { fputs("[\(Date())] \(s)\n", stderr) }

    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    static func clear() { try? Data().write(to: url) }
}

struct DiagView: View {
    @State private var text = Diag.read()
    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Chưa có nhật ký." : text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
        }
        .navigationTitle("Nhật ký")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ShareLink(item: Diag.url)
                Button { text = Diag.read() } label: { Image(systemName: "arrow.clockwise") }
                Button(role: .destructive) { Diag.clear(); text = "" } label: { Image(systemName: "trash") }
            }
        }
    }
}
