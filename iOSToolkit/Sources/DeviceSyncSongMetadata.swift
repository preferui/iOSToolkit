import Foundation
import AVFoundation
import CoreMedia

/// Đọc metadata (tiêu đề/ca sĩ/album/thể loại/năm/ảnh bìa) có sẵn TRONG chính tệp nhạc local do
/// người dùng chọn — dùng AVFoundation (API hệ thống chuẩn, không phải tra cứu backend nào).
/// Đây là phần "tìm data bài hát" hợp pháp: chỉ đọc tag ID3/MP4 đã có sẵn trong file của chính
/// người dùng, không liên quan gì tới việc tải nhạc lậu.
struct LocalSongMetadata {
    var localURL: URL
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var genre: String
    var year: Int
    var durationMs: Int
    var fileSize: Int
    var artworkData: Data?
    var remoteFilename: String
}

enum LocalSongMetadataError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Không đọc được tệp nhạc này (hỏng hoặc không có quyền truy cập)."
    }
}

enum LocalSongMetadataReader {
    /// Sinh tên tệp ngẫu nhiên 12 ký tự + đuôi gốc, giống cách Apple Music/ByeTunes đặt tên khi lưu
    /// vào vùng media của thiết bị (không dùng tên gốc, tránh trùng/ký tự lạ).
    static func generateRemoteFilename(withExtension ext: String?) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomName = String((0..<12).map { _ in letters.randomElement() ?? "A" })
        let e = (ext?.isEmpty == false ? ext! : "mp3").lowercased()
        return "\(randomName).\(e)"
    }

    static func canonicalGenre(_ raw: String?) -> String {
        guard let raw else { return "Music" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Music" }
        let lowered = trimmed.lowercased()
        let unknown: Set<String> = ["unknown", "unknown genre", "n/a", "na", "none", "null", "(null)"]
        return unknown.contains(lowered) ? "Music" : trimmed
    }

    static func read(from url: URL) async throws -> LocalSongMetadata {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 1), !head.isEmpty else {
            throw LocalSongMetadataError.unreadable
        }
        try? handle.close()

        let asset = AVURLAsset(url: url)
        let durationMs: Int
        if let duration = try? await asset.load(.duration) {
            durationMs = Int(CMTimeGetSeconds(duration) * 1000)
        } else {
            durationMs = 0
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        let filenameWithoutExt = url.deletingPathExtension().lastPathComponent
        var title = filenameWithoutExt
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var albumArtist: String?
        var genre = "Music"
        var year = Calendar.current.component(.year, from: Date())
        var artworkData: Data?

        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                case .commonKeyArtist:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
                case .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { album = value }
                case .commonKeyType:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { genre = value }
                case .commonKeyCreationDate:
                    if let value = try? await item.load(.stringValue), let y = Self.extractYear(from: value) { year = y }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) { artworkData = data }
                default: break
                }
            }
        }

        // Dò riêng TPE2/aART (album artist) trong metadata ID3/iTunes — không có trong commonMetadata.
        if let allMetadata = try? await asset.load(.metadata) {
            for item in allMetadata {
                let keyString = (item.key as? String) ?? ""
                let identifier = item.identifier?.rawValue ?? ""
                let combined = "\(identifier)|\(keyString)".uppercased()
                if combined.contains("ALBUMARTIST") || combined.contains("TPE2") || combined.contains("AART") {
                    if let value = try? await item.load(.stringValue), !value.isEmpty {
                        albumArtist = value
                    }
                }
            }
        }

        genre = canonicalGenre(genre)
        let ext = url.pathExtension
        let remoteFilename = generateRemoteFilename(withExtension: ext)

        return LocalSongMetadata(
            localURL: url, title: title, artist: artist, album: album, albumArtist: albumArtist,
            genre: genre, year: year, durationMs: durationMs, fileSize: fileSize,
            artworkData: artworkData, remoteFilename: remoteFilename
        )
    }

    private static func extractYear(from string: String) -> Int? {
        let digits = string.prefix(4).filter { $0.isNumber }
        guard digits.count == 4, let year = Int(digits) else { return nil }
        return year
    }
}
