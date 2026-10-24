import Foundation
import UIKit
import ZIPFoundation

enum IPAIcon {
    /// Lấy icon từ file icon rời trong IPA (nếu có); trả về PNG 120px.
    static func extract(from ipa: URL) -> Data? {
        guard let ar = try? Archive(url: ipa, accessMode: .read) else { return nil }
        var infoEntry: Entry?
        var pngs: [(Entry, String)] = []
        for e in ar {
            let parts = e.path.components(separatedBy: "/")
            guard parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app") else { continue }
            if parts[2] == "Info.plist" { infoEntry = e }
            else if parts[2].lowercased().hasSuffix(".png") { pngs.append((e, parts[2])) }
        }
        var stems: [String] = []
        if let infoEntry {
            var data = Data()
            _ = try? ar.extract(infoEntry) { data.append($0) }
            if let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                for k in ["CFBundleIcons", "CFBundleIcons~ipad"] {
                    if let prim = (plist[k] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any] {
                        stems += (prim["CFBundleIconFiles"] as? [String]) ?? []
                        if let n = prim["CFBundleIconName"] as? String { stems.append(n) }
                    }
                }
                stems += (plist["CFBundleIconFiles"] as? [String]) ?? []
                if let f = plist["CFBundleIconFile"] as? String { stems.append(f) }
            }
        }
        stems = stems.map { ($0 as NSString).deletingPathExtension }
        let candidates = pngs.filter { entry, name in
            stems.contains { name.hasPrefix($0) } || name.range(of: "AppIcon", options: .caseInsensitive) != nil
        }
        guard let best = candidates.max(by: { $0.0.uncompressedSize < $1.0.uncompressedSize }) else { return nil }
        var data = Data()
        _ = try? ar.extract(best.0) { data.append($0) }
        guard let img = UIImage(data: data) else { return nil }
        return render(img)
    }

    static func render(_ img: UIImage) -> Data? {
        let size = CGSize(width: 120, height: 120)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).pngData { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Dự phòng: ảnh bìa từ App Store (chỉ có khi app còn trên cửa hàng).
    static func fromStore(appID: Int64, country: String?) async -> Data? {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [URLQueryItem(name: "id", value: String(appID))] + (country.map { [URLQueryItem(name: "country", value: $0)] } ?? [])
        guard let url = comps.url, let (d, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let art = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String), let au = URL(string: art),
              let (id, _) = try? await URLSession.shared.data(from: au), let img = UIImage(data: id) else { return nil }
        return render(img)
    }
}
