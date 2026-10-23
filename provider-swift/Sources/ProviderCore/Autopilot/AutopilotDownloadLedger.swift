import Foundation

/// The builds Autopilot downloaded on the operator's behalf, beside the
/// provider config (`autopilot-downloads.json`). A restart keeps a recorded
/// build in the Autopilot set while its local weight hash still equals the
/// recorded one, even when the catalog cannot be reached; a future cleanup can
/// tell these builds from the operator's own downloads. Nothing here deletes
/// files.
public struct AutopilotDownloadLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var modelId: String
        /// `WeightHasher` hash of the verified download.
        public var weightHash: String
        public var downloadedAtMs: Int64

        public init(modelId: String, weightHash: String, downloadedAtMs: Int64) {
            self.modelId = modelId
            self.weightHash = weightHash
            self.downloadedAtMs = downloadedAtMs
        }

        enum CodingKeys: String, CodingKey {
            case modelId = "model_id", weightHash = "weight_hash", downloadedAtMs = "downloaded_at_ms"
        }
    }

    public static let fileName = "autopilot-downloads.json"
    static let maximumEntries = AutopilotModelSet.maximumCount
    static let maximumFileBytes = 262_144

    public private(set) var downloads: [Entry] = []

    public init(downloads: [Entry] = []) {
        for entry in downloads { record(entry) }
    }

    public static func url(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName)
    }

    /// Verified hash by model, for keeping recorded builds in the set.
    public var weightHashes: [String: String] {
        Dictionary(downloads.map { ($0.modelId, $0.weightHash) }, uniquingKeysWith: { _, latest in latest })
    }

    /// A newer download of the same build replaces its entry; the oldest
    /// entries go first beyond the bound.
    public mutating func record(_ entry: Entry) {
        guard AutopilotModelSet.isReportableID(entry.modelId), !entry.weightHash.isEmpty,
              entry.weightHash.utf8.count <= 128 else { return }
        downloads.removeAll { $0.modelId == entry.modelId }
        downloads.append(entry)
        if downloads.count > Self.maximumEntries { downloads.removeFirst(downloads.count - Self.maximumEntries) }
    }

    /// Missing, oversized or unreadable files read as empty: the ledger only
    /// widens the set, so losing it fails closed.
    public static func read(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url), data.count <= maximumFileBytes,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return Self(downloads: decoded.downloads)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
