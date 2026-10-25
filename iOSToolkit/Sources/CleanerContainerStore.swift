import Foundation
import UIKit

typealias CleanerMCMRootValidator = (URL) -> Bool

struct CleanerApplication: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let containerPath: String
    var id: String { bundleID }
}

enum CleanerContainerStore {
    private static let maxApplications = 4_096

    static func installedApplications(progress: ((Int, Int) -> Void)? = nil) -> (applications: [CleanerApplication], error: String?) {
        var enumerationError: NSString?
        let identifiers = MCMEnumerateIdentifiersForClass(2, UInt(maxApplications), &enumerationError)
        guard !identifiers.isEmpty else {
            return ([], enumerationError.map { String($0) } ?? "Không lấy được danh sách ứng dụng từ iOS.")
        }

        var applications: [CleanerApplication] = []
        applications.reserveCapacity(identifiers.count)
        for (index, bundleID) in identifiers.enumerated() {
            defer { progress?(index + 1, identifiers.count) }
            guard isSafeBundleIdentifier(bundleID) else { continue }
            var activationError: NSString?
            guard let rawPath = MCMActivateContainerPath(2, bundleID, false, &activationError) else { continue }
            let containerURL = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            guard isApplicationContainer(containerURL) else { continue }
            applications.append(CleanerApplication(
                bundleID: bundleID,
                name: displayName(in: containerURL, bundleID: bundleID),
                containerPath: containerURL.path
            ))
        }
        applications.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
        return (applications, nil)
    }

    static func resolveContainer(bundleID: String) -> URL? {
        guard isSafeBundleIdentifier(bundleID) else { return nil }
        var error: NSString?
        guard let path = MCMActivateContainerPath(2, bundleID, false, &error) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return isApplicationContainer(url) ? url : nil
    }

    static func isApplicationContainer(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        let roots = [
            "/var/mobile/Containers/Data/Application/",
            "/private/var/mobile/Containers/Data/Application/"
        ]
        guard roots.contains(where: { path.hasPrefix($0) }) else { return false }
        return UUID(uuidString: url.lastPathComponent) != nil
    }

    private static func displayName(in container: URL, bundleID: String) -> String {
        let metadataURL = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: metadataURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return bundleID
        }
        let metadataBundleID = plist["MCMMetadataIdentifier"] as? String
        guard metadataBundleID == bundleID else { return bundleID }
        let info = plist["MCMMetadataInfo"] as? [String: Any] ?? [:]
        return (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleID
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}





