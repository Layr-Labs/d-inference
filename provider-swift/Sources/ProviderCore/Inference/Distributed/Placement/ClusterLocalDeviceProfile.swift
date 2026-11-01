import Foundation
import DarkbloomClusterPlacement

/// This Mac's device profile as its installed plan tool reads it
/// (`darkbloom-cluster-plan device --json`), for every caller: the setup's own
/// report (which also answers the other Mac's update check and its plans), a
/// plan made on this Mac, and an automatic batch replacement. Memory and the
/// system's facts are read now. The model-free speed index (`--index`, about a
/// second of GPU work) is measured only while no model is loaded on this Mac;
/// while one is, the index this Mac last measured stands in, as long as the chip
/// and the OS build are the ones it was measured on (`ClusterDeviceIndexRecord`).
/// The control leader's update check reaches a serving member every 60 s
/// (`ClusterService.checkForUpdate`), and its report measured the index on that
/// Mac's GPU each time, beside the model it served; the re-plan after an update
/// stops both parts first, so its profiles measure the index again.
enum ClusterLocalDeviceProfile {
    /// `modelLoaded`: a model is loaded or loading on this Mac now
    /// (`ClusterService.modelLoaded()` in the product).
    static func read(tool: URL, deadline: UInt64, homeDirectory: URL, modelLoaded: Bool) throws -> ClusterDeviceProfile {
        let profile = try ClusterDeviceProfile.decode(DistributedCapabilityProbe.run(executable: tool,
            arguments: ["device", "--json"] + (modelLoaded ? [] : ["--index"]), deadline: deadline,
            maximumOutputBytes: ClusterDeviceProfile.maximumEncodedBytes))
        if let index = profile.speedIndex {
            ClusterDeviceIndexRecord.record(index, homeDirectory: homeDirectory)
            return profile
        }
        // Not measured now (a model is loaded, or the benchmark could not run): the last measurement, when it is this Mac's.
        guard let stored = ClusterDeviceIndexRecord.read(homeDirectory: homeDirectory)?.index,
              stored.chip == profile.chip, stored.osBuild == profile.osBuild else { return profile }
        var indexed = profile
        indexed.speedIndex = stored
        return (try? indexed.validate()) != nil ? indexed : profile
    }
}

/// This Mac's own model-free speed index as it last measured it, in owner-only
/// `~/.darkbloom/cluster/device-index.json`: what this Mac's profile carries
/// while a model is loaded here and no GPU benchmark may run
/// (`ClusterLocalDeviceProfile`). One index, replaced at each measurement;
/// figures only, no name or address.
struct ClusterDeviceIndexRecord: Codable, Equatable, Sendable {
    static let schemaName = "darkbloom_cluster_device_index_v1"
    static let maximumBytes = 4096
    let schema: String
    let measuredAt: Double
    let index: ClusterDeviceIndex

    init(measuredAt: Double, index: ClusterDeviceIndex) {
        schema = Self.schemaName; self.measuredAt = measuredAt; self.index = index
    }

    static func file(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/device-index.json")
    }

    /// Nil when absent, unreadable, not owner-only or malformed.
    static func read(homeDirectory: URL) -> ClusterDeviceIndexRecord? {
        guard let data = try? ClusterConfigurationFiles.read(file(homeDirectory: homeDirectory), maximum: maximumBytes, privateMode: true),
              let value = try? JSONDecoder().decode(ClusterDeviceIndexRecord.self, from: data),
              value.schema == schemaName, value.measuredAt.isFinite, (try? value.index.validate()) != nil else { return nil }
        return value
    }

    /// Keeps `index` as this Mac's last measurement. Never throws into a
    /// report or a plan: a measurement that cannot be kept only leaves the
    /// previous one standing in.
    @discardableResult
    static func record(_ index: ClusterDeviceIndex, homeDirectory: URL, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard (try? index.validate()) != nil else { return false }
        do {
            try ClusterConfigurationFiles.update(file(homeDirectory: homeDirectory), maximum: maximumBytes) { _ in
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return try encoder.encode(ClusterDeviceIndexRecord(measuredAt: now, index: index))
            }
            return true
        } catch { return false }
    }
}
