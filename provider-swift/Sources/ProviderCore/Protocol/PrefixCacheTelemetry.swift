// Copyright © 2026 Eigen Labs.

/// Numeric operational snapshots only. They carry no prompt, hash, scope, file
/// path or free-form diagnostic. Absence means uninstrumented, not zero.
public enum PrefixCacheTelemetryKind: String, Codable, Sendable, Equatable {
    case attentionBlocks = "attention_blocks"
    case completeCheckpoint = "complete_checkpoint"
}

public struct PrefixCacheTelemetry: Codable, Sendable, Equatable {
    public var kind: PrefixCacheTelemetryKind
    public var generation: UInt64 = 0
    public var sampleSeq: UInt64 = 0
    public var sampleAgeMs: UInt64 = 0
    public var entries: UInt64 = 0
    public var diskBytes: UInt64 = 0
    public var stagingBytes: UInt64 = 0
    public var stagesTotal: UInt64 = 0
    public var filesWrittenTotal: UInt64 = 0
    public var writtenBytesTotal: UInt64 = 0
    public var donationDropsTotal: UInt64 = 0
    public var corruptDropsTotal: UInt64 = 0
    public var evictionsTotal: UInt64 = 0
    public var ttlExpiredTotal: UInt64?
    public var io: PrefixCacheIOTelemetry?

    enum CodingKeys: String, CodingKey {
        case kind, io
        case ttlExpiredTotal = "ttl_expired_total"
        case generation = "generation"
        case sampleSeq = "sample_seq"
        case sampleAgeMs = "sample_age_ms"
        case entries = "entries"
        case diskBytes = "disk_bytes"
        case stagingBytes = "staging_bytes"
        case stagesTotal = "stages_total"
        case filesWrittenTotal = "files_written_total"
        case writtenBytesTotal = "written_bytes_total"
        case donationDropsTotal = "donation_drops_total"
        case corruptDropsTotal = "corrupt_drops_total"
        case evictionsTotal = "evictions_total"
    }
}

public struct PrefixCacheIOTelemetry: Codable, Sendable, Equatable {
    public var stagingPeakBytes: UInt64 = 0
    public var filesReadTotal: UInt64 = 0
    public var readBytesTotal: UInt64 = 0
    public var stageReadBytesTotal: UInt64 = 0
    public var donationReadBytesTotal: UInt64 = 0
    public var stageUsTotal: UInt64 = 0
    public var writeUsTotal: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case stagingPeakBytes = "staging_peak_bytes"
        case filesReadTotal = "files_read_total"
        case readBytesTotal = "read_bytes_total"
        case stageReadBytesTotal = "stage_read_bytes_total"
        case donationReadBytesTotal = "donation_read_bytes_total"
        case stageUsTotal = "stage_us_total"
        case writeUsTotal = "write_us_total"
    }
}

public struct PrefixCacheMaintenanceTelemetry: Codable, Sendable, Equatable {
    public var ttlExpiredTotal: UInt64 = 0
    public var budgetEvictedTotal: UInt64 = 0
    public var tempRemovedTotal: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case ttlExpiredTotal = "ttl_expired_total"
        case budgetEvictedTotal = "budget_evicted_total"
        case tempRemovedTotal = "temp_removed_total"
    }
}
