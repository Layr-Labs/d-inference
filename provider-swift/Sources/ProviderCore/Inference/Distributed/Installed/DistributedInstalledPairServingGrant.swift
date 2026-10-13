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
/// mode, read from a qualification record the runner wrote
/// (`ClusterPairQualificationRecord`). It has the shape of the coordinator's
/// parity qualification record (one class per rank in rank order, `cuts`,
/// `mode`), with chip classes where that record names each rank's registered
/// numerics class.
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
            return model + " has no grant to be served by a pair in this darkbloom: no cross-cable qualification record of it has passed. "
                + "A pair serves a model only under a grant derived from the records of passing runs, which list the chip classes each rank may run on." + policy
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

/// The pair-serving decisions a set of qualification records gives, one per
/// registered model that has a record (owner decision D4, accepted with "all
/// models" on 2026-10-09; "universal mechanisms", 2026-10-11): nothing here
/// names a model, a chip or an order. A model is
///
/// - withheld when any of its records diverged (a token other than the
///   reference's where the reference had no near tie), at any cut, mode or
///   order: a grant admits a model at every cut the planner may choose, so one
///   cut that diverged withholds it even where another passed;
/// - otherwise granted on the placements of its passing records: a class
///   reaches a role when a passing run ran it in that role;
/// - and otherwise (no record, or only inconclusive ones) undecided, which
///   refuses it as having no grant.
///
/// Every model's passed and diverged placements are also kept as shapes
/// (`shapes(runtimeModelID:)`): a model with a diverged record is planned and
/// started only at a shape a record passed in (`ClusterPairQualificationRecords`).
///
/// A record is used only when it is consistent (`isConsistent`: the runner's
/// rule re-derived, two Macs' transport, ranks and cuts in order) and every
/// rank's chip has a class; any other record is counted in `ignored`.
public struct ClusterPairServingDecisions: Sendable, Equatable {
    public let granted: [ClusterPairServingGrant]
    public let withheld: [String: String]
    public let ignored: Int
    /// The shapes of each model's passed and diverged records, de-duplicated.
    let passedShapes: [String: [ClusterPairServingQualification]]
    let failedShapes: [String: [ClusterPairServingQualification]]

    /// A model's records as shapes; a model with no record restricts none.
    public func shapes(runtimeModelID: String) -> ClusterPairQualificationRecords {
        .init(runtimeModelID: runtimeModelID, passed: passedShapes[runtimeModelID] ?? [], failed: failedShapes[runtimeModelID] ?? [])
    }

    public init(records: [ClusterPairQualificationRecord]) {
        var passed: [String: [ClusterPairServingQualification]] = [:], passedRecords: [String: Int] = [:]
        var diverged: [String: [(ClusterPairQualificationRecord, [ClusterChipClass])]] = [:]
        var ignored = 0
        for record in records {
            let classes = record.ranks.compactMap { ClusterChipClass(chipName: $0.chip) }
            guard record.isConsistent, classes.count == record.ranks.count, let mode = record.mode else { ignored += 1; continue }
            switch record.outcome {
            case .passed:
                passed[record.runtimeModelID, default: []].append(.init(chipClasses: classes, cuts: record.cuts, mode: mode))
                passedRecords[record.runtimeModelID, default: 0] += 1
            case .diverged:
                diverged[record.runtimeModelID, default: []].append((record, classes))
            case .inconclusive:
                break
            }
        }
        self.ignored = ignored
        func unique(_ runs: [ClusterPairServingQualification]) -> [ClusterPairServingQualification] {
            var kept: [ClusterPairServingQualification] = []
            for run in runs where !kept.contains(run) { kept.append(run) }
            return kept
        }
        passedShapes = passed.mapValues(unique)
        failedShapes = diverged.mapValues { runs in
            unique(runs.compactMap { record, classes in record.mode.map { .init(chipClasses: classes, cuts: record.cuts, mode: $0) } })
        }
        withheld = diverged.mapValues { Self.withholding($0) }
        granted = passed.keys.sorted().compactMap { model -> ClusterPairServingGrant? in
            guard diverged[model] == nil, let runs = passed[model] else { return nil }
            var unique: [ClusterPairServingQualification] = []
            for run in runs where !unique.contains(run) { unique.append(run) }
            unique.sort { Self.order($0.cuts, $0.mode.rawValue, $0.chipClasses) < Self.order($1.cuts, $1.mode.rawValue, $1.chipClasses) }
            return ClusterPairServingGrant(runtimeModelID: model, qualifications: unique,
                evidence: Self.evidence(records: passedRecords[model] ?? 0, placements: unique))
        }
    }

    /// A sort key: cuts (numerically), then mode, then classes.
    static func order(_ cuts: [Int], _ mode: String, _ classes: [ClusterChipClass]) -> String {
        cuts.map { String(repeating: "0", count: max(0, 8 - String($0).count)) + String($0) }.joined(separator: ",")
            + "|" + mode + "|" + classes.map(\.rawValue).joined(separator: ",")
    }

    static func placementWords(_ classes: [ClusterChipClass]) -> String {
        classes.enumerated().map { "\($0.element.rawValue) rank \($0.offset)" }.joined(separator: ", ")
    }

    static func evidence(records: Int, placements: [ClusterPairServingQualification]) -> String {
        let orders = Set(placements.map { placementWords($0.chipClasses) }).sorted()
        let cuts = Set(placements.flatMap(\.cuts)).sorted().map(String.init).joined(separator: ", ")
        let modes = Set(placements.map(\.mode.rawValue)).sorted().joined(separator: ", ")
        return "\(records) passing cross-cable qualification record\(records == 1 ? "" : "s") (near-tie rule against single-Mac references): "
            + orders.joined(separator: "; ") + "; cuts \(cuts); modes \(modes)"
    }

    /// Why a model whose records diverged is withheld: the first divergence
    /// (lowest cut, then mode) in full, and every cut that diverged.
    static func withholding(_ runs: [(ClusterPairQualificationRecord, [ClusterChipClass])]) -> String {
        let ordered = runs.sorted { order($0.0.cuts, $0.0.generationMode, $0.1) < order($1.0.cuts, $1.0.generationMode, $1.1) }
        let cuts = Array(Set(ordered.flatMap { $0.0.cuts })).sorted().map(String.init)
        let cutWords = cuts.count == 1 ? "cut \(cuts[0])" : "cuts " + cuts.dropLast().joined(separator: ", ") + " and " + cuts.last!
        guard let (record, classes) = ordered.first, let failure = record.firstFailure else {
            return "its cross-cable check diverged at \(cutWords)"
        }
        var detail = "its cross-cable check diverged at \(cutWords) (first: \(placementWords(classes)), cut \(record.cuts.map(String.init).joined(separator: ",")), "
            + "\(record.generationMode), \(record.promptTokens)-token request"
        if let index = failure.firstDivergenceIndex { detail += ", output \(index)" }
        if let gap = failure.gapInULPs {
            detail += String(format: ", %.1f ulp from the reference's choice against a near-tie threshold of %.1f", gap, failure.nearTieThresholdULPs)
        }
        if let chip = failure.referenceChip { detail += ", against the single-Mac reference recorded on an \(chip)" }
        return detail + ")"
    }
}

/// The grants this darkbloom carries, derived from the qualification records
/// it ships (`ClusterPairQualificationRecordsBundled`, written by
/// `darkbloom-cluster-pair-check record` from cross-cable runs and their
/// single-Mac references): the near-tie rule decides each record
/// (`acceptedCrossClassVerdicts`), `ClusterPairServingDecisions` decides each
/// model. Single-Mac serving requirements (`ModelRuntimeRequirements`) are
/// separate and unchanged. Adding a chip, an order or a model is adding the
/// runner's record of a passing run, not editing a table.
public enum ClusterPairServingGrants {
    /// The comparator verdicts a cross-cable check may have and pass.
    /// `diverged` and `incomparable` fail it.
    public static let acceptedCrossClassVerdicts = ClusterPairQualificationRecord.acceptedVerdicts

    /// The records this build ships. A bundle that does not decode gives no
    /// records, so every model is refused (a check guards the bundle).
    public static let records: [ClusterPairQualificationRecord] =
        (try? ClusterPairQualificationRecord.decodeLines(ClusterPairQualificationRecordsBundled.jsonLines)) ?? []

    public static let decisions = ClusterPairServingDecisions(records: records)

    public static var granted: [ClusterPairServingGrant] { decisions.granted }
    /// Registered models whose records diverged, and why.
    public static var withheld: [String: String] { decisions.withheld }

    /// Every check of a model on record, passed and failed, in each
    /// qualification's shape, from the bundled records
    /// (`ClusterPairServingDecisions.shapes`).
    public static func records(runtimeModelID: String,
                               decisions: ClusterPairServingDecisions = decisions) -> ClusterPairQualificationRecords {
        decisions.shapes(runtimeModelID: runtimeModelID)
    }

    /// The grant for a model a pair may serve; a refusal for every other model.
    public static func grant(runtimeModelID: String, publicModelID: String,
                             decisions: ClusterPairServingDecisions = decisions) throws -> ClusterPairServingGrant {
        if let grant = decisions.granted.first(where: { $0.runtimeModelID == runtimeModelID }) { return grant }
        throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
            reason: decisions.withheld[runtimeModelID].map { .withheld($0) } ?? .noGrant)
    }

    /// One rank of a placement, checked on the Mac that runs it with that
    /// Mac's own chip class. Every rank checked this way is the whole placement.
    public static func requireRank(_ rank: Int, of rankCount: Int, chipClass: ClusterChipClass?,
                                   runtimeModelID: String, publicModelID: String,
                                   cuts: [Int]? = nil, mode: ClusterGenerationMode? = nil,
                                   decisions: ClusterPairServingDecisions = decisions) throws {
        let grant = try grant(runtimeModelID: runtimeModelID, publicModelID: publicModelID, decisions: decisions)
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
        let checks = records(runtimeModelID: runtimeModelID, decisions: decisions)
        if checks.restrictsShapes {
            guard let cuts, let mode, checks.admitsRank(rank, of: rankCount, chipClass: chipClass, cuts: cuts, mode: mode) else {
                throw refuse(.shapeNotQualified(rank: rank, chipClass: chipClass, cuts: cuts ?? [], mode: mode ?? .pipeline,
                    qualified: checks.passedShapesText))
            }
        }
    }

    /// A whole placement: each rank's chip class in rank order.
    public static func requirePlacement(_ rankClasses: [ClusterChipClass?], runtimeModelID: String, publicModelID: String,
                                        cuts: [Int]? = nil, mode: ClusterGenerationMode? = nil,
                                        decisions: ClusterPairServingDecisions = decisions) throws {
        guard rankClasses.count >= 2 else {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                reason: .placementShape(rank: 0, rankCount: rankClasses.count))
        }
        for (rank, chipClass) in rankClasses.enumerated() {
            try requireRank(rank, of: rankClasses.count, chipClass: chipClass,
                            runtimeModelID: runtimeModelID, publicModelID: publicModelID, cuts: cuts, mode: mode,
                            decisions: decisions)
        }
        // Each rank's half holds; under shape restriction the classes must
        // also come from one passed check together.
        let checks = records(runtimeModelID: runtimeModelID, decisions: decisions)
        if checks.restrictsShapes, let cuts, let mode, let last = rankClasses.last.flatMap({ $0 }),
           !checks.admits(chipClasses: rankClasses, cuts: cuts, mode: mode) {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                reason: .shapeNotQualified(rank: rankClasses.count - 1, chipClass: last, cuts: cuts, mode: mode,
                    qualified: checks.passedShapesText))
        }
    }
}
