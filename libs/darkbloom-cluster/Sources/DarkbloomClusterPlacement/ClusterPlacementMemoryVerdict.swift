import Foundation

/// Whether a model fits a set of Macs, as data for the screens to present: the planner's own placement on the
/// Macs as they are, and, when none fits, on the same Macs with each GPU limit raised to its ceiling
/// (`ClusterGPUMemoryLimit`). One rule decides all three answers, so a model offered as fitting is one each
/// Mac's load gate admits at rest and its GPU can keep resident.
public enum ClusterPlacementMemoryVerdict: Codable, Equatable, Sendable {
    /// A placement fits the Macs as they are (`ClusterPlacementCandidate.possible`).
    case fits
    /// A placement fits once these Macs' GPU limits are raised; nothing fits before.
    case needsGPULimitRaise([ClusterGPULimitRaise])
    /// Nothing fits, even with every GPU limit at its ceiling.
    case doesNotFit

    /// The plan to follow and its verdict: `plan` on `devices`, and, when it chooses nothing that fits, `plan`
    /// again with every GPU limit below its ceiling raised. `plan` is the caller's whole planning step (the
    /// planner itself, or the setup's flow around it), so the verdict is that step's own answer.
    public static func assess(devices: [ClusterPlacementDevice],
                              plan: ([ClusterPlacementDevice]) throws -> ClusterPlacementResult)
        throws -> (verdict: ClusterPlacementMemoryVerdict, result: ClusterPlacementResult) {
        let now = try plan(devices)
        if now.chosen?.possible == true { return (.fits, now) }
        let raised = try devices.map { device in
            try device.profile.withGPUMemoryLimitRaised().map { ClusterPlacementDevice(label: device.label, profile: $0, speed: device.speed) }
        }
        guard raised.contains(where: { $0 != nil }) else { return (.doesNotFit, now) }
        let after = try plan(zip(devices, raised).map { $1 ?? $0 })
        guard let chosen = after.chosen, chosen.possible else { return (.doesNotFit, now) }
        let raises = chosen.ranks.compactMap { rank -> ClusterGPULimitRaise? in
            guard let device = devices.first(where: { $0.label == rank.device }),
                  let need = rank.gpuResidentBytes, need > device.profile.residentCapacityBytes else { return nil }
            return ClusterGPULimitRaise(device: rank.device, gpuNeedBytes: need,
                currentLimitBytes: device.profile.residentCapacityBytes,
                defaultLimit: device.profile.wiredLimitBytes == nil,
                raiseToMegabytes: ClusterGPUMemoryLimit.ceilingMegabytes(physicalMemoryBytes: device.profile.physicalMemoryBytes))
        }
        // The raised plan may differ only in the live gate's answer; then the limits are not what stops it.
        guard !raises.isEmpty else { return (.doesNotFit, now) }
        return (.needsGPULimitRaise(raises), after)
    }
}

/// One Mac's GPU limit raise: what the placement keeps resident there, the limit now and the ceiling it is raised to.
public struct ClusterGPULimitRaise: Codable, Equatable, Sendable {
    public let device: String
    public let gpuNeedBytes: Int
    public let currentLimitBytes: Int
    /// True while the limit is macOS's default (`iogpu.wired_limit_mb=0`, Metal's recommended working set).
    public let defaultLimit: Bool
    /// `iogpu.wired_limit_mb` to set.
    public let raiseToMegabytes: Int
    public var raiseToBytes: Int { raiseToMegabytes << 20 }

    public init(device: String, gpuNeedBytes: Int, currentLimitBytes: Int, defaultLimit: Bool, raiseToMegabytes: Int) {
        self.device = device; self.gpuNeedBytes = gpuNeedBytes; self.currentLimitBytes = currentLimitBytes
        self.defaultLimit = defaultLimit; self.raiseToMegabytes = raiseToMegabytes
    }

    /// The question for one Mac, in whole GB of 2^30 bytes as the Macs' memory is named ("128 GB"): the need
    /// rounded up, the limits rounded down, so neither side is overstated.
    public func question(model: String, mac: String) -> String {
        let need = (gpuNeedBytes + (1 << 30) - 1) >> 30, limit = currentLimitBytes >> 30, to = raiseToBytes >> 30
        return "\(model) needs \(need) GB of GPU memory on \(mac); macOS allows \(limit) GB"
            + (defaultLimit ? " by default" : " as it is set now")
            + ". Allow Darkbloom to raise it to \(to) GB? (one password prompt; kept after a restart)"
    }
}
