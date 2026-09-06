// Copyright © 2026 Eigen Labs.

/// Queue-captured allocator observations. Overlapping byte gauges are not
/// additive owners or admission inputs; absent instrumentation remains absent.
public struct PagedStorageTelemetry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable { case segmented }
    public var kind: Kind = .segmented
    public var generation: UInt64 = 0
    public var sampleSeq: UInt64 = 0
    public var sampleAgeMs: UInt64 = 0
    public var grantBytes: UInt64 = 0
    public var committedBytes: UInt64 = 0
    public var reservedPageBytes: UInt64 = 0
    public var livePageBytes: UInt64 = 0
    public var poisonBytes: UInt64 = 0
    public var slackBytes: UInt64 = 0
    public var overGrantBytes: UInt64 = 0
    public var segmentCount: UInt64 = 0
    public var addressPages: UInt64 = 0
    /// Allocator bytes that cannot hold logical KV pages; absent on older producers.
    public var allocatorPaddingBytes: UInt64?
    /// Unused conservative allowance released after the last successful preparation.
    public var lastAllocationAllowanceBytes: UInt64?
    public var nominalKVBytes: UInt64?
    public var physicalFloorOverheadBytes: UInt64?
    public var allocationFailuresTotal: UInt64?
    public var admissionRefusalsTotal: UInt64?
    public var grantRefusalsTotal: UInt64?
    public var grantEpochRetriesTotal: UInt64?

    enum CodingKeys: String, CodingKey {
        case kind
        case generation = "generation"
        case sampleSeq = "sample_seq"
        case sampleAgeMs = "sample_age_ms"
        case grantBytes = "grant_bytes"
        case committedBytes = "committed_bytes"
        case reservedPageBytes = "reserved_page_bytes"
        case livePageBytes = "live_page_bytes"
        case poisonBytes = "poison_bytes"
        case slackBytes = "slack_bytes"
        case overGrantBytes = "over_grant_bytes"
        case segmentCount = "segment_count"
        case addressPages = "address_pages"
        case allocatorPaddingBytes = "allocator_padding_bytes"
        case lastAllocationAllowanceBytes = "last_allocation_allowance_bytes"
        case nominalKVBytes = "nominal_kv_bytes"
        case physicalFloorOverheadBytes = "physical_floor_overhead_bytes"
        case allocationFailuresTotal = "allocation_failures_total"
        case admissionRefusalsTotal = "admission_refusals_total"
        case grantRefusalsTotal = "grant_refusals_total"
        case grantEpochRetriesTotal = "grant_epoch_retries_total"
    }
}
