import Foundation
import Darwin
import DarkbloomClusterProtocol

/// The chip class of one Mac: its chip family and tier, spelled
/// `apple_m3_ultra`, `apple_m5_max`, `apple_m4` (no tier word for the base
/// chip). A pair-serving grant lists the chip classes each role may run on
/// (owner decision D4); across classes a pair passes on the owner's near-tie
/// rule. The coordinator derives the same class, by the same rule, from a
/// member's attested chip name for its own per-role grant
/// (`decoding_rank_chip_classes`, `pipeline_rank_chip_classes`).
///
/// A chip class is not a member's registered numerics class
/// (`device_profile.numerics_class`, which also names the GPU architecture,
/// the Metal library and the operating system). That one is what a cluster
/// approval's `allowed_numerics_classes` and a parity qualification's
/// `numerics_classes` compare; it is not an input here.
///
/// A class is read from the chip's own name on the Mac that runs the rank.
/// It is never taken from a capability record, a saved setup, a peer or a
/// runtime capability: a kernel capability such as `mlx_nax` is not a class
/// and does not make one, so claiming it opens nothing.
public struct ClusterChipClass: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// The class of a chip as the system names it (`machdep.cpu.brand_string`
    /// or the display report's model name): "Apple", then the family, then at
    /// most one tier word. Anything else, a virtual machine's "Apple M1
    /// (Virtual)" included, has no class and is granted nothing.
    public init?(chipName: String) {
        let words = chipName.lowercased().split(separator: " ").map(String.init)
        guard (2...3).contains(words.count), words[0] == "apple" else { return nil }
        let family = words[1]
        guard family.count == 2, family.first == "m", let digit = family.last, ("1"..."9").contains(digit) else { return nil }
        let tier = words.count == 3 ? words[2] : nil
        guard tier.map({ ["pro", "max", "ultra"].contains($0) }) ?? true else { return nil }
        rawValue = "apple_" + family + (tier.map { "_" + $0 } ?? "")
    }

    /// This Mac's class, from the kernel's brand string: no GPU, no child
    /// process. Nil when the chip has no class.
    public static func local() -> ClusterChipClass? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return ClusterChipClass(chipName: String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self))
    }

    public static let appleM3Ultra = ClusterChipClass(chipName: "Apple M3 Ultra")!
    public static let appleM5Max = ClusterChipClass(chipName: "Apple M5 Max")!
    public static let appleM5Ultra = ClusterChipClass(chipName: "Apple M5 Ultra")!

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a rank does in a placement, which is what a grant restricts.
public enum ClusterPairServingRole: String, Sendable, CaseIterable {
    /// The last rank. It holds the model's final layers and head and selects
    /// every token; under a phase split it decodes alone with every layer, and
    /// with MTP it also drafts and verifies.
    case decodingRank = "decoding_rank"
    /// Every other rank: it holds leading layers and runs the prompt (and, as a
    /// pipeline, its layers of each decode step), and never selects a token.
    case pipelineRank = "pipeline_rank"

    /// The role of `rank` in a placement of `rankCount` ranks, in every
    /// generation mode this runtime has. Nil for a rank outside the placement.
    public static func of(rank: Int, rankCount: Int) -> Self? {
        guard rankCount >= 2, (0..<rankCount).contains(rank) else { return nil }
        return rank == rankCount - 1 ? .decodingRank : .pipelineRank
    }
}

/// One placement a cross-cable check ran and passed under the near-tie rule:
/// each rank's chip class in rank order, the layer cuts and the generation
/// mode. It has the shape of the coordinator's parity qualification record
/// (one class per rank in rank order, `cuts`, `mode`), with chip classes where
/// that record names each rank's registered numerics class.
///
/// A grant's role classes come from its qualifications only: a class reaches
/// a role when a passed check ran it in that role. The cut and the mode are
/// not part of the provider's decision (a pair is planned from each Mac's
/// detected hardware, at whatever cut fits); public traffic is bounded to the
/// exact classes, cuts and mode by the coordinator's parity qualification.
public struct ClusterPairServingQualification: Sendable, Equatable {
    public let chipClasses: [ClusterChipClass]
    public let cuts: [Int]
    public let mode: ClusterGenerationMode

    /// The shape the coordinator requires of a parity qualification: two or
    /// more ranks, one cut fewer than the ranks, cuts positive and ascending.
    public var isWellFormed: Bool {
        chipClasses.count >= 2 && cuts.count == chipClasses.count - 1 && cuts.allSatisfy { $0 > 0 }
            && zip(cuts, cuts.dropFirst()).allSatisfy { $0 < $1 }
    }
}

/// One registered model's grant to be served by a pair: the chip classes each
/// role may run on, derived from the placements its cross-cable checks passed
/// in. A placement is served only when every rank's class is listed for its
/// role. Keyed by the runtime's own model identity, which comes from the
/// worker's capability record and which a setup cannot rename; the public
/// model identity only names the model in a refusal.
///
/// This is the provider's half of owner decision 4 (operator approval per
/// model with allowed chip classes per rank). Public traffic also needs the
/// coordinator's promotable parity qualification for the exact classes, cuts
/// and mode; a placement without one serves its owner only.
public struct ClusterPairServingGrant: Sendable, Equatable {
    public let runtimeModelID: String
    /// The placements the grant rests on.
    public let qualifications: [ClusterPairServingQualification]
    /// The same runs in plain words.
    public let evidence: String
    /// Every class a qualification ran as its last rank.
    public var decodingRankChipClasses: Set<ClusterChipClass> { Set(qualifications.compactMap(\.chipClasses.last)) }
    /// Every class a qualification ran at a rank before its last.
    public var pipelineRankChipClasses: Set<ClusterChipClass> { Set(qualifications.flatMap { $0.chipClasses.dropLast() }) }

    public func chipClasses(for role: ClusterPairServingRole) -> Set<ClusterChipClass> {
        switch role {
        case .decodingRank: decodingRankChipClasses
        case .pipelineRank: pipelineRankChipClasses
        }
    }

    /// Every class some rank may have.
    public var chipClasses: Set<ClusterChipClass> { decodingRankChipClasses.union(pipelineRankChipClasses) }
}

/// Every cross-cable check of one model on record, passed and failed, each
/// in the shape of a parity qualification (each rank's chip class in rank
/// order, the cuts, the mode).
///
/// The universal rule these records carry: a model whose numerics depend on
/// the shape of its placement shows it by failing a check at some shape, on
/// any chips. From then on the cut and the mode are part of what a pair may
/// run: a placement is planned and served only when a passed check ran
/// exactly its shape. A model with no failed check keeps a grant by role and
/// chip class only. Records decide; no model or chip is named by the rule.
public struct ClusterPairQualificationRecords: Sendable, Equatable {
    public let runtimeModelID: String
    public let passed: [ClusterPairServingQualification]
    public let failed: [ClusterPairServingQualification]

    public var restrictsShapes: Bool { !failed.isEmpty }

    /// A whole placement's shape: a passed check ran exactly it. Every
    /// shape is admitted when the records restrict none.
    public func admits(chipClasses: [ClusterChipClass?], cuts: [Int], mode: ClusterGenerationMode) -> Bool {
        guard restrictsShapes else { return true }
        let classes = chipClasses.compactMap { $0 }
        guard classes.count == chipClasses.count else { return false }
        return passed.contains { $0.chipClasses == classes && $0.cuts == cuts && $0.mode == mode }
    }

    /// One rank's half of `admits`, decided on the Mac that runs the rank
    /// with only its own class: some passed check ran a placement of this many
    /// ranks with this class at this rank, at these cuts, in this mode.
    public func admitsRank(_ rank: Int, of rankCount: Int, chipClass: ClusterChipClass, cuts: [Int],
                           mode: ClusterGenerationMode) -> Bool {
        guard restrictsShapes else { return true }
        return passed.contains { q in
            q.chipClasses.count == rankCount && q.chipClasses.indices.contains(rank) && q.chipClasses[rank] == chipClass
                && q.cuts == cuts && q.mode == mode
        }
    }

    /// The passed shapes in plain words.
    public var passedShapesText: String {
        passed.isEmpty ? "none" : passed.map { q in
            q.chipClasses.map(\.rawValue).joined(separator: " then ") + " at cut " + q.cuts.map(String.init).joined(separator: "/")
                + " (" + q.mode.rawValue + ")"
        }.joined(separator: "; ")
    }
}

/// Why a pair may not serve a placement.
public struct ClusterPairServingRefusal: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public enum Reason: Equatable, Sendable {
        /// This build has no grant and no decision for the model.
        case noGrant
        /// A grant was considered and withheld, for this reason.
        case withheld(String)
        /// The placement has fewer than two ranks, or the rank is outside it.
        case placementShape(rank: Int, rankCount: Int)
        /// The Mac that runs this rank has a chip with no chip class.
        case unknownChip(rank: Int, role: ClusterPairServingRole)
        /// This rank's class is not listed for its role.
        case classNotAllowed(rank: Int, role: ClusterPairServingRole, chipClass: ClusterChipClass, allowed: [ClusterChipClass])
        /// The model's grant restricts shapes, and no passed check ran this
        /// rank's class at this rank with these cuts in this mode.
        case shapeNotQualified(rank: Int, chipClass: ClusterChipClass, cuts: [Int], mode: ClusterGenerationMode, qualified: String)
    }
    public let runtimeModelID: String
    public let publicModelID: String
    public let reason: Reason

    public var errorDescription: String? { description }
    public var description: String {
        let model = "This cluster's model, \(publicModelID) (registered as \(runtimeModelID)),"
        let policy = " That is a policy decision about this model, not a fault in the setup, and no cluster setting changes it."
        switch reason {
        case .noGrant:
            return model + " has no grant to be served by a pair in this darkbloom. A pair serves a model only under a grant that lists the chip classes each rank may run on." + policy
        case .withheld(let why):
            return model + " is not granted pair serving: \(why)." + policy
        case .placementShape(let rank, let rankCount):
            return model + " cannot be placed: rank \(rank) of a placement of \(rankCount) ranks. A pair-serving grant applies to two or more ranks in order."
        case .unknownChip(let rank, let role):
            return model + " cannot run rank \(rank) (the \(role.words)) on this Mac: its chip has no chip class, so no grant can list it. "
                + "A chip class is the chip family and tier read on the Mac that runs the rank; a kernel capability such as mlx_nax does not make one." + policy
        case .classNotAllowed(let rank, let role, let chipClass, let allowed):
            return model + " is granted pair serving with the \(role.words) on \(allowed.map(\.rawValue).joined(separator: " or ")); "
                + "rank \(rank) of this placement is that rank and runs on \(chipClass.rawValue). "
                + "A chip class is the chip family and tier read on the Mac that runs the rank; a kernel capability such as mlx_nax does not change it. "
                + "Choose a placement whose ranks run on the listed classes; a class is added only after a cross-cable check on it passes." + policy
        case .shapeNotQualified(let rank, let chipClass, let cuts, let mode, let qualified):
            return model + " diverged from its single-Mac reference in a cross-cable check at some placement, so a pair serves it only "
                + "at placements a check passed in (each rank's chip class, the cut, the mode): \(qualified). "
                + "Rank \(rank) of this placement runs on \(chipClass.rawValue) at cut \(cuts.map(String.init).joined(separator: "/")) "
                + "in \(mode.rawValue), which no passed check covers. Plan again (`darkbloom cluster plan` keeps to the passed placements); "
                + "a placement is added only after a cross-cable check of it passes." + policy
        }
    }
}

extension ClusterPairServingRole {
    var words: String { self == .decodingRank ? "decoding rank" : "pipeline-only rank" }
}

/// The grants this darkbloom carries: one decision for every model the
/// runtime registers, granted with chip classes per role or withheld with the
/// reason. Owner decision D4 (2026-10-09, accepted with "all models" on
/// 2026-10-09 22:20 PDT): a model whose cross-cable check passed is granted on
/// the classes and roles that check ran; the check passes when its tokens
/// equal the single-Mac reference or first differ at a near tie
/// (`acceptedCrossClassVerdicts`). Single-Mac serving requirements
/// (`ModelRuntimeRequirements`) are separate and unchanged.
public enum ClusterPairServingGrants {
    /// The comparator verdicts a cross-cable check may have and pass.
    /// `diverged` and `incomparable` fail it.
    public static let acceptedCrossClassVerdicts = ["exact", "tokensEqualLogitsDiffer", "divergedAtNearTie"]

    private static let m3Ultra = ClusterChipClass.appleM3Ultra, m5Max = ClusterChipClass.appleM5Max
    private static let m5Ultra = ClusterChipClass.appleM5Ultra
    /// M3 Ultra rank 0, M5 Ultra rank 1 (the decoding rank), checked since
    /// 2026-10-12 for the 9B and the 27B at the product's plan.
    private static let m3UltraLeadsM5Ultra = [m3Ultra, m5Ultra]
    /// The order every family's checks ran in: M3 Ultra rank 0, M5 Max rank 1
    /// (the decoding rank).
    private static let m3UltraLeads = [m3Ultra, m5Max]
    /// The mirrored order, checked for the 27B only.
    private static let m5MaxLeads = [m5Max, m3Ultra]

    /// The passed checks of one order at one cut, one per mode.
    private static func passed(_ chipClasses: [ClusterChipClass], cut: Int, _ modes: ClusterGenerationMode...) -> [ClusterPairServingQualification] {
        modes.map { .init(chipClasses: chipClasses, cuts: [cut], mode: $0) }
    }
    /// The failed checks of one order at one cut, one per mode.
    private static func failed(_ chipClasses: [ClusterChipClass], cut: Int, _ modes: ClusterGenerationMode...) -> [ClusterPairServingQualification] {
        modes.map { .init(chipClasses: chipClasses, cuts: [cut], mode: $0) }
    }

    public static let qwen35_9b = ClusterPairServingGrant(runtimeModelID: "registered_qwen35_9b",
        qualifications: passed(m3UltraLeads, cut: 4, .pipeline, .phaseSplit, .phaseSplitMTP)
            + passed(m3UltraLeadsM5Ultra, cut: 16, .phaseSplitMTP),
        evidence: "M3 Ultra rank 0 and M5 Max rank 1 at cut 4 across the cable: pipeline and phase split with prompts of 5,120 to 30,720 tokens, "
            + "phase split with MTP; every comparison against both Macs' references a near tie or tokens equal; "
            + "M3 Ultra rank 0 and M5 Ultra rank 1 (2026-10-12, cut 16, phase split with MTP): tokens equal Mac A's reference, "
            + "a near tie against the M5 Ultra's (evidence universal-20261010/m5ultra/hw/9b/)")
    /// Both orders ran: the M3 Ultra decodes in the mirrored one.
    public static let qwen38_27b = ClusterPairServingGrant(runtimeModelID: "registered_qwen38_27b",
        qualifications: passed(m3UltraLeads, cut: 16, .pipeline, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP)
            + passed(m5MaxLeads, cut: 48, .pipeline, .pipelineCompactDecode, .phaseSplit)
            + passed(m3UltraLeadsM5Ultra, cut: 32, .phaseSplitMTP),
        evidence: "M3 Ultra rank 0 and M5 Max rank 1 (cut 16): pipeline, compact decode, phase split, phase split with MTP, "
            + "prefix reuse and prompts to 30,720 tokens; M5 Max rank 0 and M3 Ultra rank 1 (cut 48): pipeline, compact decode "
            + "and phase split; every comparison against both Macs' references a near tie (0 to 1 ulp) or tokens equal; "
            + "M3 Ultra rank 0 and M5 Ultra rank 1 (2026-10-12, cut 32, phase split with MTP): tokens equal both Macs' references "
            + "(evidence universal-20261010/m5ultra/hw/27b/)")
    public static let qwen35_35b_a3b = ClusterPairServingGrant(runtimeModelID: "registered_qwen35_35b_a3b",
        qualifications: passed(m3UltraLeads, cut: 12, .pipeline, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP)
            + passed(m3UltraLeads, cut: 20, .pipeline, .phaseSplit, .phaseSplitMTP),
        evidence: "cuts 12 and 20, pipeline, compact decode, phase split and phase split with MTP: a near tie (0 ulp) broken the way "
            + "the M5 Max alone breaks it, or tokens equal; 5,120 tokens equal")
    public static let qwen36_35b_a3b = ClusterPairServingGrant(runtimeModelID: "registered_qwen36_35b_a3b",
        qualifications: passed(m3UltraLeads, cut: 12, .pipeline, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP)
            + passed(m3UltraLeads, cut: 20, .pipeline, .phaseSplit, .phaseSplitMTP),
        evidence: "cuts 12 and 20, text only, pipeline, compact decode, phase split and phase split with MTP: tokens equal the M3 Ultra's "
            + "reference or first differ at a near tie (0 to 1 ulp)")
    public static let bonsai_2_27b = ClusterPairServingGrant(runtimeModelID: "registered_ternary_bonsai_2_27b",
        qualifications: passed(m3UltraLeads, cut: 24, .pipeline, .pipelineCompactDecode, .phaseSplit)
            + passed(m3UltraLeads, cut: 32, .pipeline),
        evidence: "cut 24, 8,192 prompt tokens, pipeline (serial and lookahead), compact decode and phase split: all 128 tokens equal; "
            + "cut 32, 4,096 prompt tokens, pipeline: tokens equal")
    public static let nemotron35_lightning = ClusterPairServingGrant(runtimeModelID: "registered_nemotron35_lightning",
        qualifications: passed(m3UltraLeads, cut: 25, .pipeline, .pipelineCompactDecode, .phaseSplit)
            + passed(m3UltraLeads, cut: 27, .pipeline) + passed(m3UltraLeads, cut: 20, .phaseSplit),
        evidence: "cut 25, short prompt, pipeline, compact decode and phase split: tokens equal, or a near tie (4.0 ulp against the "
            + "M5 Max's reference, the comparator's threshold); cut 27 pipeline and cut 20 phase split at 4,096 tokens: tokens equal or a near tie")

    public static let granted: [ClusterPairServingGrant] = [qwen35_9b, qwen38_27b, qwen35_35b_a3b, qwen36_35b_a3b,
                                                             bonsai_2_27b, nemotron35_lightning]

    /// Registered models whose cross-cable checks have not all passed, and
    /// why. Whatever this decides, a model with a failed check on record is
    /// planned only at shapes a check passed (`records`).
    public static let withheld: [String: String] = [
        "registered_gpt_oss_20b": "its cross-cable check diverged at cuts 8 and 10 with an M5 Max decoding and at cut 4 with an M5 Ultra decoding (output 1 of the 4,096-token request, reference margins 0.51 to 0.82, not near ties), although cut 12 gave the reference's tokens on both pairs",
        "registered_mimo_v26_flash_mopd": "its 4,096-token cross-cable request departs from the reference at output 50 and the departure is not classified (the reference recorded no logits there), although the short request gave the reference's tokens",
        "registered_gemma4_26b_qat_4bit": "its cross-cable check diverged at cut 12 (token 7 of the 31-token request, margin 0.30, not a near tie), although cuts 15 and 18 passed",
        "registered_gemma4_26b_8bit": "its cross-cable check diverged at cut 12 (tokens 21 and 20 of the 4,096- and 5,120-token requests, margins of 0.25 and more, not near ties)",
        "registered_gemma4_26b": "no cross-cable check has run on this artifact",
    ]

    /// The failed checks of a model on record (`diverged` or `incomparable`
    /// against a single-Mac reference), each in a qualification's shape. One
    /// entry is enough to restrict the model's shapes (`ClusterPairQualificationRecords`).
    public static let failedChecks: [String: [ClusterPairServingQualification]] = [
        // M3 Ultra rank 0: with an M5 Max decoding at cuts 8 and 10 (2026-10-09/10, pipeline serial and lookahead,
        // compact decode); with an M5 Ultra decoding at cut 4 (2026-10-12, serial and lookahead).
        "registered_gpt_oss_20b": failed(m3UltraLeads, cut: 8, .pipeline, .pipelineCompactDecode)
            + failed(m3UltraLeads, cut: 10, .pipeline, .pipelineCompactDecode)
            + failed(m3UltraLeadsM5Ultra, cut: 4, .pipeline),
    ]

    /// The passed checks of a withheld model, kept on record so that its plan
    /// keeps to them. A granted model's passed checks are its grant's.
    public static let withheldPassedChecks: [String: [ClusterPairServingQualification]] = [
        // Cut 12 pipeline, the 4,096-token request: tokens equal both Macs' references with an M5 Max decoding
        // (2026-10-11) and with an M5 Ultra decoding (2026-10-12, serial and lookahead).
        "registered_gpt_oss_20b": passed(m3UltraLeads, cut: 12, .pipeline) + passed(m3UltraLeadsM5Ultra, cut: 12, .pipeline),
    ]

    /// Every check of a model on record, passed and failed.
    public static func records(runtimeModelID: String) -> ClusterPairQualificationRecords {
        .init(runtimeModelID: runtimeModelID,
              passed: granted.first { $0.runtimeModelID == runtimeModelID }?.qualifications ?? withheldPassedChecks[runtimeModelID] ?? [],
              failed: failedChecks[runtimeModelID] ?? [])
    }

    /// The grant for a model a pair may serve; a refusal for every other model.
    public static func grant(runtimeModelID: String, publicModelID: String) throws -> ClusterPairServingGrant {
        if let grant = granted.first(where: { $0.runtimeModelID == runtimeModelID }) { return grant }
        throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
            reason: withheld[runtimeModelID].map { .withheld($0) } ?? .noGrant)
    }

    /// One rank of a placement, checked on the Mac that runs it with that
    /// Mac's own chip class. Every rank checked this way is the whole placement.
    public static func requireRank(_ rank: Int, of rankCount: Int, chipClass: ClusterChipClass?,
                                   runtimeModelID: String, publicModelID: String,
                                   cuts: [Int]? = nil, mode: ClusterGenerationMode? = nil) throws {
        let grant = try grant(runtimeModelID: runtimeModelID, publicModelID: publicModelID)
        func refuse(_ reason: ClusterPairServingRefusal.Reason) -> ClusterPairServingRefusal {
            .init(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: reason)
        }
        guard let role = ClusterPairServingRole.of(rank: rank, rankCount: rankCount) else {
            throw refuse(.placementShape(rank: rank, rankCount: rankCount))
        }
        guard let chipClass else { throw refuse(.unknownChip(rank: rank, role: role)) }
        let allowed = grant.chipClasses(for: role)
        guard allowed.contains(chipClass) else {
            throw refuse(.classNotAllowed(rank: rank, role: role, chipClass: chipClass, allowed: allowed.sorted()))
        }
        // A shape-restricted grant needs the placement's shape: a caller that
        // does not give it is refused rather than admitted at any cut.
        let checks = records(runtimeModelID: runtimeModelID)
        if checks.restrictsShapes {
            guard let cuts, let mode, checks.admitsRank(rank, of: rankCount, chipClass: chipClass, cuts: cuts, mode: mode) else {
                throw refuse(.shapeNotQualified(rank: rank, chipClass: chipClass, cuts: cuts ?? [], mode: mode ?? .pipeline,
                    qualified: checks.passedShapesText))
            }
        }
    }

    /// A whole placement: each rank's chip class in rank order.
    public static func requirePlacement(_ rankClasses: [ClusterChipClass?], runtimeModelID: String, publicModelID: String,
                                        cuts: [Int]? = nil, mode: ClusterGenerationMode? = nil) throws {
        guard rankClasses.count >= 2 else {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                reason: .placementShape(rank: 0, rankCount: rankClasses.count))
        }
        for (rank, chipClass) in rankClasses.enumerated() {
            try requireRank(rank, of: rankClasses.count, chipClass: chipClass,
                            runtimeModelID: runtimeModelID, publicModelID: publicModelID, cuts: cuts, mode: mode)
        }
        // Each rank's half holds; under shape restriction the classes must
        // also come from one passed check together.
        let checks = records(runtimeModelID: runtimeModelID)
        if checks.restrictsShapes, let cuts, let mode, let last = rankClasses.last.flatMap({ $0 }),
           !checks.admits(chipClasses: rankClasses, cuts: cuts, mode: mode) {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                reason: .shapeNotQualified(rank: rankClasses.count - 1, chipClass: last, cuts: cuts, mode: mode,
                    qualified: checks.passedShapesText))
        }
    }
}
