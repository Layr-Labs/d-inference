import Foundation

struct PlacementMeasurementContext: Codable, Hashable, Sendable {
    let identity: PlacementIdentity
    let workload: PlacementWorkload
    let costBasis: PlacementCostBasis
    let evidenceSHA256: String
    let sampleCount: Int
}

struct PlacementLocalMeasurement: Codable, Sendable {
    let id: String
    let context: PlacementMeasurementContext
    let phase: PlacementPhase
    let step: Int
    let rank: Int
    let operators: [String]
    let isWeightLoad: Bool // operators contains exact physical weight IDs here.
    let operatorPlacements: [String: PlacementAssignment]
    let resources: [PlacementResource]
    let nanoseconds: UInt64
    // This interval excludes transport and contains the complete listed local
    // work. A fused stage uses one measurement; summing nominal FLOPs is absent.
}

enum PlacementEncryptionCost: Codable, Sendable {
    case unprotectedDiagnostic
    case authenticated(sealBytesPerSecond: UInt64, openBytesPerSecond: UInt64,
                       fixedNanosecondsPerRecord: UInt64)
}

struct PlacementLinkMeasurement: Codable, Sendable {
    let id: String
    let context: PlacementMeasurementContext
    let source: Int
    let destination: Int
    let minimumPlaintextBytes: UInt64
    let maximumPlaintextBytes: UInt64
    let maximumPlaintextBytesPerRecord: UInt64
    let wireOverheadBytesPerRecord: UInt64
    let minimumRecords: UInt64
    let maximumRecords: UInt64
    let latencyNanosecondsPerRecord: UInt64
    let effectiveWireBytesPerSecond: UInt64
    let encryption: PlacementEncryptionCost
    // Measured fit valid only within the explicit byte/record domain and exact
    // identity/workload/profile. Network and seal/open components must have
    // disjoint timing scopes. Include the observed fit error as this margin.
    let fitMarginNanoseconds: UInt64
}

struct PlacementMeasurements: Codable, Sendable {
    let local: [PlacementLocalMeasurement]
    let links: [PlacementLinkMeasurement]
}

enum PlacementError: Error, Equatable, CustomStringConvertible {
    case invalid(String), missingMeasurement(String), mismatch(String)
    case memory(rank: Int, required: UInt64, available: UInt64)
    case overflow, cyclicGraph, scheduleWidth
    var description: String {
        switch self {
        case .invalid(let value): return "invalid: " + value
        case .missingMeasurement(let value): return "unmeasured: " + value
        case .mismatch(let value): return "calibration mismatch: " + value
        case .memory(let rank, let required, let available):
            return "rank \(rank) requires \(required) B; observed available \(available) B"
        case .overflow: return "checked arithmetic overflow"
        case .cyclicGraph: return "cyclic execution graph"
        case .scheduleWidth: return "ready frontier exceeds 64 tasks"
        }
    }
}

enum PlacementMath {
    static func sum(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { value, next in
            let (result, overflow) = value.addingReportingOverflow(next)
            guard !overflow else { throw PlacementError.overflow }
            return result
        }
    }
    static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw PlacementError.overflow }
        return value
    }
    static func ceilingRatio(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        guard b > 0 else { throw PlacementError.invalid("zero rate") }
        return a / b + (a % b == 0 ? 0 : 1)
    }
    static func bytesTime(_ bytes: UInt64, rate: UInt64) throws -> UInt64 {
        try ceilingRatio(multiply(bytes, 1_000_000_000), rate)
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && value.contains(where: { $0 != "0" })
    }
    static func name(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 33 || $0.value == 127 }
    }
}
