import Foundation

/// Downloads Autopilot may make on the operator's behalf
/// (`[backend.autopilot_downloads]` in `provider.toml`). On by default for a
/// Mac with saved Autopilot consent, unless the operator turns them off or
/// limits them; provider configuration, never part of the consent record, so
/// changing it never changes the Autopilot revision.
public struct AutopilotDownloadSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Cap on the storage the builds Autopilot downloaded may use, in GiB;
    /// nil means no operator cap.
    public var maxStorageGb: UInt64?
    /// Cap on the number of builds Autopilot downloaded; nil means no cap.
    public var maxModels: UInt64?
    /// GiB of free disk to keep after a download; nil uses
    /// `AutopilotDiskGuard.defaultReserveGiB`.
    public var reserveGb: UInt64?

    public init(enabled: Bool = true, maxStorageGb: UInt64? = nil, maxModels: UInt64? = nil,
                reserveGb: UInt64? = nil) {
        self.enabled = enabled
        self.maxStorageGb = maxStorageGb
        self.maxModels = maxModels
        self.reserveGb = reserveGb
    }

    enum CodingKeys: String, CodingKey {
        case enabled, maxStorageGb = "max_storage_gb", maxModels = "max_models", reserveGb = "reserve_gb"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxStorageGb = try c.decodeIfPresent(UInt64.self, forKey: .maxStorageGb)
        maxModels = try c.decodeIfPresent(UInt64.self, forKey: .maxModels)
        reserveGb = try c.decodeIfPresent(UInt64.self, forKey: .reserveGb)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(maxStorageGb, forKey: .maxStorageGb)
        try c.encodeIfPresent(maxModels, forKey: .maxModels)
        try c.encodeIfPresent(reserveGb, forKey: .reserveGb)
    }

    var reserveBytes: Int64 { AutopilotDiskGuard.bytes(gib: reserveGb ?? AutopilotDiskGuard.defaultReserveGiB) }
    var limitBytes: Int64? { maxStorageGb.map(AutopilotDiskGuard.bytes(gib:)) }
    var limitModels: Int? { maxModels.map { Int(clamping: $0) } }
}

/// Where the next download stands against the disk reserve and the
/// operator's caps. Usage counts the builds Autopilot downloaded that are
/// still on disk, so deleting one frees its share.
public struct AutopilotDownloadBudget: Sendable, Equatable {
    public var freeBytes: Int64?
    public var reserveBytes: Int64
    public var usedBytes: Int64
    public var usedModels: Int
    public var limitBytes: Int64?
    public var limitModels: Int?

    public init(freeBytes: Int64?, reserveBytes: Int64, usedBytes: Int64, usedModels: Int,
                limitBytes: Int64? = nil, limitModels: Int? = nil) {
        self.freeBytes = freeBytes
        self.reserveBytes = reserveBytes
        self.usedBytes = usedBytes
        self.usedModels = usedModels
        self.limitBytes = limitBytes
        self.limitModels = limitModels
    }

    /// Before the size is known: a cap already reached refuses a new build.
    public var refusalBeforeSizing: AutopilotDownloadRefusal? {
        if let limitModels, usedModels >= limitModels { return .modelLimitReached }
        if let limitBytes, usedBytes >= limitBytes { return .storageLimitReached }
        return nil
    }

    /// Once the bytes still to fetch are known. An unknown free figure
    /// refuses: the guard fails closed.
    public func refusal(neededBytes: Int64) -> AutopilotDownloadRefusal? {
        if let refusal = refusalBeforeSizing { return refusal }
        let needed = max(0, neededBytes)
        if let limitBytes {
            let (total, overflow) = usedBytes.addingReportingOverflow(needed)
            if overflow || total > limitBytes { return .storageLimitReached }
        }
        return AutopilotDiskGuard.allows(neededBytes: needed, freeBytes: freeBytes, reserveBytes: reserveBytes)
            ? nil : .insufficientDisk
    }

    /// The `download_storage` report.
    public var report: ModelAutopilotDownloadStorage {
        ModelAutopilotDownloadStorage(diskFreeBytes: max(0, freeBytes ?? 0), reserveBytes: reserveBytes,
            usedBytes: usedBytes, usedModels: usedModels, limitBytes: limitBytes, limitModels: limitModels)
    }
}
