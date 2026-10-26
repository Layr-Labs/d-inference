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
        /// Stored bytes of the build, counted against the storage cap while
        /// it is on disk.
        public var sizeBytes: Int64

        public init(modelId: String, weightHash: String, downloadedAtMs: Int64, sizeBytes: Int64 = 0) {
            self.modelId = modelId
            self.weightHash = weightHash
            self.downloadedAtMs = downloadedAtMs
            self.sizeBytes = sizeBytes
        }

        enum CodingKeys: String, CodingKey {
            case modelId = "model_id", weightHash = "weight_hash", downloadedAtMs = "downloaded_at_ms"
            case sizeBytes = "size_bytes"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelId = try c.decode(String.self, forKey: .modelId)
            weightHash = try c.decode(String.self, forKey: .weightHash)
            downloadedAtMs = try c.decode(Int64.self, forKey: .downloadedAtMs)
            sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
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

    /// Storage and builds Autopilot downloaded that are still on disk,
    /// optionally leaving one build out (a re-download replaces it).
    public func usage(excluding modelId: String? = nil,
                      onDisk: (String) -> Bool) -> (bytes: Int64, models: Int) {
        downloads.reduce(into: (bytes: Int64(0), models: 0)) { total, entry in
            guard entry.modelId != modelId, onDisk(entry.modelId) else { return }
            let (sum, overflow) = total.bytes.addingReportingOverflow(max(0, entry.sizeBytes))
            total.bytes = overflow ? .max : sum
            total.models += 1
        }
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

    /// Owner-only from creation: the bytes go to a 0600 sibling that is then
    /// renamed over the ledger.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: try encoder.encode(self),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path])
        }
        guard rename(staging.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
