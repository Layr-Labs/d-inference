import Foundation

enum Gemma4MTPDeltaError: Error, Equatable {
    case envelope, identity, range, overflow, allowance, transition
}

enum Gemma4MTPDeltaBytes {
    static func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value)
            guard value >= 0, !overflow else { throw Gemma4MTPDeltaError.overflow }
            return next
        }
    }
    static func product(_ values: [Int]) throws -> Int {
        try values.reduce(1) { total, value in
            let (next, overflow) = total.multipliedReportingOverflow(by: value)
            guard value > 0, !overflow else { throw Gemma4MTPDeltaError.overflow }
            return next
        }
    }
}

/// Geometry only. This does not admit a workload, certify a scope hash, or
/// replace the original owner/ledger. The future adapter must bind a NEW v2
/// scope to the existing request, epoch, builds, artifacts and chosen policy.
struct Gemma4MTPDeltaEnvelope: Equatable {
    let scopeSHA256: String
    let promptTokens: Int
    let outputCount: Int
    var initialFrontier: Int { promptTokens + 1 }
    var maximumFrontier: Int { promptTokens + outputCount - 1 }
    var maximumReseedFrontier: Int { promptTokens + outputCount - 3 }
    var maximumDeltaPositions: Int { outputCount - 4 }

    init(scopeSHA256: String, promptTokens: Int, outputCount: Int) throws {
        guard scopeSHA256.utf8.count == 64,
              scopeSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...8192).contains(promptTokens), [16, 128].contains(outputCount),
              promptTokens + outputCount - 1 <= 8319 else {
            throw Gemma4MTPDeltaError.envelope
        }
        self.scopeSHA256 = scopeSHA256
        self.promptTokens = promptTokens
        self.outputCount = outputCount
    }
}

/// Provenance identity, NOT a KV-content hash. Actual target-owned capture
/// provenance and completed tensor validation remain runtime obligations.
struct Gemma4MTPDeltaSnapshot: Equatable {
    let scopeSHA256: String
    let ordinal: UInt64
    let frontier: Int
    let seed: Int
    let hiddenDType: Int

    init(envelope: Gemma4MTPDeltaEnvelope, ordinal: UInt64, frontier: Int,
         seed: Int, hiddenDType: Int) throws {
        guard (envelope.initialFrontier...envelope.maximumReseedFrontier).contains(frontier),
              ordinal <= UInt64(envelope.maximumDeltaPositions),
              (0..<262_144).contains(seed), (1...3).contains(hiddenDType) else {
            throw Gemma4MTPDeltaError.identity
        }
        self.scopeSHA256 = envelope.scopeSHA256
        self.ordinal = ordinal
        self.frontier = frontier
        self.seed = seed
        self.hiddenDType = hiddenDType
    }

    var canonicalFields: [String] {
        [scopeSHA256, String(ordinal), String(frontier), String(seed), String(hiddenDType)]
    }
}

struct Gemma4MTPDeltaDescriptor: Equatable {
    let base: Gemma4MTPDeltaSnapshot
    let next: Gemma4MTPDeltaSnapshot
    let appended: Range<Int>
    let oldSliding: Range<Int>
    let newSliding: Range<Int>
    let retainedSliding: Range<Int>

    init(envelope: Gemma4MTPDeltaEnvelope, base: Gemma4MTPDeltaSnapshot,
         next: Gemma4MTPDeltaSnapshot) throws {
        let (ordinal, overflow) = base.ordinal.addingReportingOverflow(1)
        guard !overflow, base.scopeSHA256 == envelope.scopeSHA256,
              next.scopeSHA256 == envelope.scopeSHA256, next.ordinal == ordinal,
              base.frontier >= envelope.initialFrontier,
              next.frontier <= envelope.maximumReseedFrontier,
              next.frontier > base.frontier,
              next.frontier - base.frontier <= envelope.maximumDeltaPositions,
              next.hiddenDType == base.hiddenDType else { throw Gemma4MTPDeltaError.range }
        self.base = base; self.next = next
        appended = base.frontier..<next.frontier
        oldSliding = max(0, base.frontier - 1024)..<base.frontier
        newSliding = max(0, next.frontier - 1024)..<next.frontier
        // d <= 124 < 1024, so the complete suffix exists in the target's
        // chronological sliding capture and the retained prefix is nonempty.
        retainedSliding = max(oldSliding.lowerBound, newSliding.lowerBound)..<base.frontier
        guard retainedSliding.count + appended.count == newSliding.count,
              appended.lowerBound >= newSliding.lowerBound else { throw Gemma4MTPDeltaError.range }
    }

    /// Proposed v2 associated-data input; not a wire encoder or crypto proof.
    /// Bind tensor index/shape/dtype/byte count in the eventual frame as well.
    var canonicalBytes: Data {
        let fields = ["gemma4_mtp_conditioning_delta_v2"] + base.canonicalFields + next.canonicalFields
            + [String(appended.lowerBound), String(appended.upperBound),
               String(oldSliding.lowerBound), String(oldSliding.upperBound),
               String(newSliding.lowerBound), String(newSliding.upperBound),
               String(retainedSliding.lowerBound), String(retainedSliding.upperBound)]
        return Data((fields.joined(separator: "\n") + "\n").utf8)
    }
}
