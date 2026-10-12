import Foundation
import Darwin
import DarkbloomClusterProtocol

/// The numerics class of one Mac: its chip family and tier, spelled
/// `apple_m3_ultra`, `apple_m5_max`, `apple_m4` (no tier word for the base
/// chip). Two Macs of one class give exactly equal results for one artifact
/// and runtime; across classes a pair passes on the owner's near-tie rule
/// (decision D4). The spelling is the coordinator's: a member's
/// `device_profile.numerics_class` and a cluster approval's
/// `allowed_numerics_classes` (darkbloom-platform, `native_pair_catalog_file.go`).
///
/// A class is read from the chip's own name on the Mac that runs the rank.
/// It is never taken from a capability record, a saved setup, a peer or a
/// runtime capability: a kernel capability such as `mlx_nax` is not a class
/// and does not make one, so claiming it opens nothing.
public struct ClusterNumericsClass: Hashable, Comparable, Sendable, CustomStringConvertible {
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
    public static func local() -> ClusterNumericsClass? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return ClusterNumericsClass(chipName: String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self))
    }

    public static let appleM3Ultra = ClusterNumericsClass(chipName: "Apple M3 Ultra")!
    public static let appleM5Max = ClusterNumericsClass(chipName: "Apple M5 Max")!
    public static let appleM5Ultra = ClusterNumericsClass(chipName: "Apple M5 Ultra")!

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

/// One registered model's grant to be served by a pair: the numerics classes
/// each role may run on. A placement is served only when every rank's class
/// is listed for its role. Keyed by the runtime's own model identity, which
/// comes from the worker's capability record and which a setup cannot
/// rename; the public model identity only names the model in a refusal.
///
/// This is the provider's half of owner decision 4 (operator approval per
/// model with allowed chip classes per rank). Public traffic also needs the
/// coordinator's promotable parity qualification for the exact classes, cut
/// and mode; a placement without one serves its owner only.
public struct ClusterPairServingGrant: Sendable, Equatable {
    public let runtimeModelID: String
    public let decodingRankAllowedNumericsClasses: Set<ClusterNumericsClass>
    public let pipelineRankAllowedNumericsClasses: Set<ClusterNumericsClass>
    /// The cross-cable runs the grant rests on, in plain words.
    public let evidence: String

    public func allowedNumericsClasses(for role: ClusterPairServingRole) -> Set<ClusterNumericsClass> {
        switch role {
        case .decodingRank: decodingRankAllowedNumericsClasses
        case .pipelineRank: pipelineRankAllowedNumericsClasses
        }
    }

    /// Every class some rank may have: what the coordinator's cluster
    /// approval lists as `allowed_numerics_classes` for this model.
    public var allowedNumericsClasses: Set<ClusterNumericsClass> {
        decodingRankAllowedNumericsClasses.union(pipelineRankAllowedNumericsClasses)
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
        /// The Mac that runs this rank has a chip with no numerics class.
        case unknownChip(rank: Int, role: ClusterPairServingRole)
        /// This rank's class is not listed for its role.
        case classNotAllowed(rank: Int, role: ClusterPairServingRole, numericsClass: ClusterNumericsClass, allowed: [ClusterNumericsClass])
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
            return model + " cannot run rank \(rank) (the \(role.words)) on this Mac: its chip has no numerics class, so no grant can list it. "
                + "A class is the chip family and tier read on the Mac that runs the rank; a kernel capability such as mlx_nax does not make one." + policy
        case .classNotAllowed(let rank, let role, let numericsClass, let allowed):
            return model + " is granted pair serving with the \(role.words) on \(allowed.map(\.rawValue).joined(separator: " or ")); "
                + "rank \(rank) of this placement is that rank and runs on \(numericsClass.rawValue). "
                + "A class is the chip family and tier read on the Mac that runs the rank; a kernel capability such as mlx_nax does not change it. "
                + "Choose a placement whose ranks run on the listed classes; a class is added only after a cross-cable check on it passes." + policy
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

    private static let m3Ultra = ClusterNumericsClass.appleM3Ultra, m5Max = ClusterNumericsClass.appleM5Max
    private static let m5Ultra = ClusterNumericsClass.appleM5Ultra

    /// The orientation every family's check ran in: M3 Ultra rank 0, M5 Max
    /// rank 1 (the decoding rank).
    private static func normalOrder(_ runtimeModelID: String, _ evidence: String) -> ClusterPairServingGrant {
        .init(runtimeModelID: runtimeModelID, decodingRankAllowedNumericsClasses: [m5Max],
              pipelineRankAllowedNumericsClasses: [m3Ultra], evidence: evidence)
    }

    /// The M5 Ultra decodes since 2026-10-12: M3 Ultra rank 0 and M5 Ultra rank 1 at the product's plan (cut 16, phase split
    /// with MTP), tokens equal Mac A's reference (`tokensEqualLogitsDiffer`) and a near tie at output 33 against the M5
    /// Ultra's own (`divergedAtNearTie`); evidence `universal-20261010/m5ultra/hw/9b/`.
    public static let qwen35_9b = ClusterPairServingGrant(runtimeModelID: "registered_qwen35_9b",
        decodingRankAllowedNumericsClasses: [m5Max, m5Ultra], pipelineRankAllowedNumericsClasses: [m3Ultra],
        evidence: "M3 Ultra rank 0 and M5 Max rank 1 across the cable since 2026-10-08: pipeline, compact decode, phase split, "
        + "phase split with MTP, prefix reuse and prompts to 30,720 tokens; every comparison exact, tokens equal or a near tie; "
        + "M3 Ultra rank 0 and M5 Ultra rank 1 (2026-10-12, cut 16, phase split with MTP): tokens equal Mac A's reference, a near tie against the M5 Ultra's")
    /// Both orders ran: the M3 Ultra decodes in the mirrored one.
    /// The M5 Ultra decodes since 2026-10-12 (M3 Ultra rank 0, cut 32, phase split with MTP: tokens equal both Macs'
    /// references; evidence `universal-20261010/m5ultra/hw/27b/`).
    public static let qwen38_27b = ClusterPairServingGrant(runtimeModelID: "registered_qwen38_27b",
        decodingRankAllowedNumericsClasses: [m3Ultra, m5Max, m5Ultra], pipelineRankAllowedNumericsClasses: [m3Ultra, m5Max],
        evidence: "M3 Ultra rank 0 and M5 Max rank 1 (cut 16): pipeline, compact decode, phase split, phase split with MTP, "
            + "prefix reuse and prompts to 30,720 tokens; M5 Max rank 0 and M3 Ultra rank 1 (cuts 48 and 40): pipeline, compact decode "
            + "and phase split; every comparison against both Macs' references exact, tokens equal or a near tie (1 ulp); "
            + "M3 Ultra rank 0 and M5 Ultra rank 1 (2026-10-12, cut 32, phase split with MTP): tokens equal both Macs' references")
    public static let qwen35_35b_a3b = normalOrder("registered_qwen35_35b_a3b",
        "cut 12, pipeline, compact decode and phase split: a near tie (0 ulp) broken the way the M5 Max alone breaks it; 5,120 tokens equal")
    public static let qwen36_35b_a3b = normalOrder("registered_qwen36_35b_a3b",
        "cut 12, text only, pipeline, compact decode and phase split: tokens equal the M3 Ultra's reference; 5,120 tokens a near tie (1 ulp)")
    public static let bonsai_2_27b = normalOrder("registered_ternary_bonsai_2_27b",
        "cut 24, 8,192 prompt tokens, pipeline (serial and lookahead), compact decode and phase split: all 128 tokens equal")
    public static let nemotron35_lightning = normalOrder("registered_nemotron35_lightning",
        "short prompt, pipeline, compact decode and phase split: tokens equal")

    public static let granted: [ClusterPairServingGrant] = [qwen35_9b, qwen38_27b, qwen35_35b_a3b, qwen36_35b_a3b,
                                                             bonsai_2_27b, nemotron35_lightning]

    /// Registered models whose cross-cable check has not passed, and why.
    public static let withheld: [String: String] = [
        "registered_gpt_oss_20b": "its cross-cable check diverged at output 1 of the 4,096-token request (reference margin 0.82, not a near tie)",
        "registered_mimo_v26_flash_mopd": "its 4,096-token cross-cable request departs from the reference at output 50 and the departure is not classified (no logits were recorded)",
        "registered_gemma4_26b_qat_4bit": "its cross-cable check diverged at cut 12 (token 7 of the 31-token request, margin 0.30, not a near tie); cut 18 passed, and a grant is per model, not per cut",
        "registered_gemma4_26b_8bit": "its cross-cable check diverged at cut 12 (tokens 21 and 20 of the 4,096- and 5,120-token requests, margins of 0.25 and more, not near ties)",
        "registered_gemma4_26b": "no cross-cable check has run on this artifact",
    ]

    /// The grant for a model a pair may serve; a refusal for every other model.
    public static func grant(runtimeModelID: String, publicModelID: String) throws -> ClusterPairServingGrant {
        if let grant = granted.first(where: { $0.runtimeModelID == runtimeModelID }) { return grant }
        throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
            reason: withheld[runtimeModelID].map { .withheld($0) } ?? .noGrant)
    }

    /// One rank of a placement, checked on the Mac that runs it with that
    /// Mac's own class. Every rank checked this way is the whole placement.
    public static func requireRank(_ rank: Int, of rankCount: Int, numericsClass: ClusterNumericsClass?,
                                   runtimeModelID: String, publicModelID: String) throws {
        let grant = try grant(runtimeModelID: runtimeModelID, publicModelID: publicModelID)
        func refuse(_ reason: ClusterPairServingRefusal.Reason) -> ClusterPairServingRefusal {
            .init(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: reason)
        }
        guard let role = ClusterPairServingRole.of(rank: rank, rankCount: rankCount) else {
            throw refuse(.placementShape(rank: rank, rankCount: rankCount))
        }
        guard let numericsClass else { throw refuse(.unknownChip(rank: rank, role: role)) }
        let allowed = grant.allowedNumericsClasses(for: role)
        guard allowed.contains(numericsClass) else {
            throw refuse(.classNotAllowed(rank: rank, role: role, numericsClass: numericsClass, allowed: allowed.sorted()))
        }
    }

    /// A whole placement: each rank's class in rank order.
    public static func requirePlacement(_ rankClasses: [ClusterNumericsClass?], runtimeModelID: String, publicModelID: String) throws {
        guard rankClasses.count >= 2 else {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                reason: .placementShape(rank: 0, rankCount: rankClasses.count))
        }
        for (rank, numericsClass) in rankClasses.enumerated() {
            try requireRank(rank, of: rankClasses.count, numericsClass: numericsClass,
                            runtimeModelID: runtimeModelID, publicModelID: publicModelID)
        }
    }
}
