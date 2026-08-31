import Foundation

enum LegacyMediaCleanup {
    static func purgeVideoTempFiles(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        else { return }
        for url in entries where isLegacyVideoName(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isLegacyVideoName(_ name: String) -> Bool {
        let prefix = "vlm-"
        let suffix = ".mp4"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return false
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(name[start..<end])) != nil
    }
}
