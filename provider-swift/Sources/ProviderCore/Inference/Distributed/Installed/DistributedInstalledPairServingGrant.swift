import Foundation
import os
import Darwin
import DarkbloomClusterProtocol

/// The chip class of one Mac: its chip family and tier, spelled
/// `apple_m3_ultra`, `apple_m5_max`, `apple_m4` (no tier word for the base
/// chip). A pair-serving grant lists no chip class (owner, 2026-10-14: chips
/// and memory do not gate what is offered): a passing record approves its
/// mode family on any class, and a class matters only as part of a chip
/// combination a diverged record ran (`ClusterPairQualificationRecords`).
/// A Mac whose chip has no class (not Apple silicon as the system names it,
/// a virtual machine) cannot run a rank.
///
/// A chip class is not a member's registered numerics class
/// (`device_profile.numerics_class`, which also names the GPU architecture,
/// the Metal library and the operating system). That one is what a parity
/// qualification's `numerics_classes` compare; it is not an input here.
///
/// A class is read from the chip's own name on the Mac that runs the rank.
/// It is never taken from a capability record, a saved setup, a peer or a
/// runtime capability: a kernel capability such as `mlx_nax` is not a class
/// and does not make one.
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
    /// process. Nil when the chip has no class. A debug build may be told to
    /// check ranks as another chip (`ClusterBenchChip`, developer bench only);
    /// a release build never reads it.
    public static func local(environment: [String: String] = ProcessInfo.processInfo.environment,
                             debugBuild: Bool = ClusterBenchChip.isDebugBuild) -> ClusterChipClass? {
        if let bench = ClusterBenchChip.chipName(environment: environment, debugBuild: debugBuild) {
            return ClusterChipClass(chipName: bench)
        }
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return ClusterChipClass(chipName: String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self))
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a rank does in a placement (named in a refusal; a grant does not
/// restrict roles).
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

/// Which generation modes one qualification record speaks for (owner sign-off
/// O9, mode-bound grants). Modes of one family run the same per-layer
/// arithmetic on the same ranks and differ only in how messages travel, so a
/// passing check of one is evidence for the others; across families the
/// computation differs (a speculative verify window, a split of every layer,
/// a hand-off of the request state), so a record grants only its own family.
///
/// - `pipeline`: the pipeline and its compact decode.
/// - `pipelineSpeculative`: the pipeline with speculative (MTP) rounds.
/// - `tensorParallel`: every layer split across the ranks.
/// - `handOff`: the modes that hand the request to one rank (phase split,
///   phase split with MTP, the prefill/decode hybrids): kept in code, off by
///   default, never chosen automatically.
///
/// A mode this runtime gains later must name its family here (the switch in
/// `ClusterGenerationMode.servingFamily` is exhaustive), so no new mode is
/// ever served on another family's records.
public enum ClusterPairServingModeFamily: String, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    case pipeline = "pipeline"
    case pipelineSpeculative = "pipeline_speculative"
    case tensorParallel = "tensor_parallel"
    case handOff = "hand_off"

    /// The family in plain words.
    public var description: String {
        switch self {
        case .pipeline: "pipeline"
        case .pipelineSpeculative: "pipeline with speculative rounds"
        case .tensorParallel: "tensor parallel"
        case .handOff: "hand-off (phase split)"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

extension ClusterGenerationMode {
    /// The mode family a qualification record of this mode grants.
    public var servingFamily: ClusterPairServingModeFamily {
        switch self {
        case .pipeline, .pipelineCompactDecode: .pipeline
        case .pipelineMTP: .pipelineSpeculative
        case .tensorParallel: .tensorParallel
        case .phaseSplit, .phaseSplitMTP, .pipelinePrefillTensorDecode: .handOff
        }
    }
}

/// One placement a cross-cable check ran: each rank's chip class in rank
/// order, the layer cuts and the generation mode, read from a qualification
/// record the runner wrote (`ClusterPairQualificationRecord`). It has the shape
/// of the coordinator's parity qualification record (one class per rank in
/// rank order, `cuts`, `mode`), with chip classes where that record names each
/// rank's registered numerics class.
///
/// A passed placement is evidence for its model, artifact and mode family on
/// any Apple silicon (owner, 2026-10-14: chips and memory do not gate what is
/// offered); a diverged one restricts only its own chip combination and shape
/// (`ClusterPairQualificationRecords`). Public traffic is bounded to the exact
/// classes, cuts and mode by the coordinator's parity qualification.
public struct ClusterPairServingQualification: Sendable, Equatable {
    public let chipClasses: [ClusterChipClass]
    public let cuts: [Int]
    public let mode: ClusterGenerationMode

    /// The mode family this placement's check speaks for.
    public var family: ClusterPairServingModeFamily { mode.servingFamily }

    /// The chip combination: the classes regardless of rank order.
    public var combination: [ClusterChipClass] { chipClasses.sorted() }

    /// The shape the coordinator requires of a parity qualification: two or
    /// more ranks, one cut fewer than the ranks, cuts positive and ascending.
    public var isWellFormed: Bool {
        chipClasses.count >= 2 && cuts.count == mode.layerCutCount(ranks: chipClasses.count) && cuts.allSatisfy { $0 > 0 }
            && zip(cuts, cuts.dropFirst()).allSatisfy { $0 < $1 }
    }
}

/// One registered model's PUBLIC grant: the mode families its passing
/// cross-cable checks ran, each qualified for public traffic on any detected
/// Apple silicon the planner can place it on. The owner's own serving never
/// needs it (`ClusterPairOwnerServing`). No chip class is listed for any role:
/// a chip decides nothing here except through a diverged record of its exact
/// combination (`ClusterPairQualificationRecords`), and memory decides only
/// what fits (the planner and each Mac's load gate). Keyed by the runtime's
/// own model identity, which comes from the worker's capability record and
/// which a setup cannot rename; the public model identity only names the
/// model in a refusal.
///
/// Public traffic also needs the coordinator's cluster approval and, for the
/// exact classes, cuts and mode, its promotable parity qualification; a
/// placement without one serves its owner only.
public struct ClusterPairServingGrant: Sendable, Equatable {
    public let runtimeModelID: String
    /// The placements the grant rests on: the passed checks of its granted
    /// families only.
    public let qualifications: [ClusterPairServingQualification]
    /// The same runs in plain words.
    public let evidence: String
    /// The families with a diverged record and no passing one, and why: never
    /// served, on any chips, until a check of the family passes.
    public let withheldFamilies: [ClusterPairServingModeFamily: String]

    public init(runtimeModelID: String, qualifications: [ClusterPairServingQualification], evidence: String,
                withheldFamilies: [ClusterPairServingModeFamily: String] = [:]) {
        self.runtimeModelID = runtimeModelID; self.qualifications = qualifications; self.evidence = evidence
        self.withheldFamilies = withheldFamilies
    }

    /// The mode families a pair may serve this model in, in order.
    public var families: [ClusterPairServingModeFamily] { Set(qualifications.map(\.family)).sorted() }

    /// The chip classes the grant's passing checks ran on, in any role: what
    /// the evidence says in words. Not a list of allowed chips: any detected
    /// Apple silicon may run any rank of a granted family.
    public var qualifiedChipClasses: Set<ClusterChipClass> { Set(qualifications.flatMap(\.chipClasses)) }
}

/// Every cross-cable check of one model on record, passed and failed, each
/// in the shape of a parity qualification (each rank's chip class in rank
/// order, the cuts, the mode).
///
/// What a diverged record does (owner, 2026-10-14 08:45): it steers the
/// planner and the start away from the exact shape that diverged, on the chips
/// that ran it, and nothing else. Records never decide whether the owner may
/// serve a model; they decide public traffic (`ClusterPairServingGrant`, the
/// coordinator's parity qualification) and these shapes:
///
/// - a placement is refused only when it IS a shape that diverged (each rank's
///   class in rank order, the cuts, the mode family); on that same chip
///   combination every other shape is admitted, whether or not a check passed
///   in it;
/// - a Mac checks its rank with its own class only (it cannot see its
///   partner's), so a rank whose class ran a diverged shape at that rank
///   refuses that exact rank-shape (rank count, cuts, family) with any partner;
///   the planner and the offer apply the same half, so they pick another cut;
/// - the planner refuses a model on these grounds only when every shape these
///   Macs can hold diverged.
///
/// Records decide; no model or chip is named by the rule.
public struct ClusterPairQualificationRecords: Sendable, Equatable {
    public let runtimeModelID: String
    public let passed: [ClusterPairServingQualification]
    public let failed: [ClusterPairServingQualification]

    /// Some mode family of the model has a failed check.
    public var restrictsShapes: Bool { !failed.isEmpty }

    /// The families some failed check restricts.
    public var restrictedFamilies: Set<ClusterPairServingModeFamily> { Set(failed.map(\.family)) }

    public func restricts(_ family: ClusterPairServingModeFamily) -> Bool { failed.contains { $0.family == family } }

    /// Whether a failed check of this family ran this chip combination.
    public func restrictsCombination(_ classes: [ClusterChipClass], family: ClusterPairServingModeFamily) -> Bool {
        let combination = classes.sorted()
        return failed.contains { $0.family == family && $0.combination == combination }
    }

    /// A whole placement: every classed rank's own half (`admitsRank`). With
    /// every class known that refuses exactly the shapes that diverged (and the
    /// rank-shapes a class diverged at); any other shape on the same chips is
    /// admitted. A rank with no class (a test profile, a virtual machine) is
    /// left to its own start, which refuses it, unless the classed ranks could
    /// be a shape that diverged at these cuts.
    public func admits(chipClasses: [ClusterChipClass?], cuts: [Int], mode: ClusterGenerationMode) -> Bool {
        let family = mode.servingFamily
        guard restricts(family) else { return true }
        for (rank, chipClass) in chipClasses.enumerated() {
            if let chipClass, !admitsRank(rank, of: chipClasses.count, chipClass: chipClass, cuts: cuts, mode: mode) { return false }
        }
        guard chipClasses.contains(where: { $0 == nil }) else { return true }
        return !failed.contains { q in
            q.family == family && q.chipClasses.count == chipClasses.count && q.cuts == cuts
                && zip(q.chipClasses, chipClasses).allSatisfy { ran, here in here.map { $0 == ran } ?? true }
        }
    }

    /// One rank's half of `admits`, decided on the Mac that runs the rank with
    /// only its own class: no failed check of this family ran this class at
    /// this rank of a placement of this many ranks at these cuts.
    public func admitsRank(_ rank: Int, of rankCount: Int, chipClass: ClusterChipClass, cuts: [Int],
                           mode: ClusterGenerationMode) -> Bool {
        let family = mode.servingFamily
        return !failed.contains { q in
            q.family == family && q.chipClasses.count == rankCount && q.chipClasses.indices.contains(rank)
                && q.chipClasses[rank] == chipClass && q.cuts == cuts
        }
    }

    /// The passed shapes in plain words.
    public var passedShapesText: String { Self.shapesText(passed) }
    /// The diverged shapes in plain words.
    public var failedShapesText: String { Self.shapesText(failed) }

    static func shapesText(_ runs: [ClusterPairServingQualification]) -> String {
        runs.isEmpty ? "none" : runs.map { q in
            q.chipClasses.map(\.rawValue).joined(separator: " then ") + " at cut " + q.cuts.map(String.init).joined(separator: "/")
                + " (" + q.mode.rawValue + ")"
        }.joined(separator: "; ")
    }
}

/// Why a pair may not serve a placement, or why a model has no public grant.
///
/// For the owner's own use (owner, 2026-10-14 08:45) a pair refuses a model
/// only when no cluster stage adapter runs it (`noStageAdapter`) or when the
/// two Macs cannot hold it in any sharded layout (the planner's memory
/// refusal, not a value here); a rank is refused only when it cannot be
/// checked (`placementShape`, `unknownChip`, `modeMissing`) or when it is a
/// shape that diverged on its chips (`shapeDiverged`). `noGrant`, `withheld`
/// and `artifactNotQualified` say why a model has no PUBLIC grant
/// (`ClusterPairServingGrants.grant`); they never stop the owner's serving.
public struct ClusterPairServingRefusal: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Public traffic: this build has no passing record of the model.
        case noGrant
        /// Public traffic: the model's records diverged and none passed, for this reason.
        case withheld(String)
        /// Owner and public: no cluster stage adapter of this build runs the
        /// model, in any sharded mode.
        case noStageAdapter
        /// The placement has fewer than two ranks, or the rank is outside it.
        case placementShape(rank: Int, rankCount: Int)
        /// The Mac that runs this rank has a chip with no chip class (not
        /// Apple silicon as the system names it, or a virtual machine).
        case unknownChip(rank: Int, role: ClusterPairServingRole)
        /// The rank was checked without its generation mode.
        case modeMissing(rank: Int)
        /// This rank's class at this rank, with these cuts, in this mode
        /// family, is a shape that diverged from the single-Mac reference in a
        /// cross-cable check (`diverged` lists every shape that did).
        case shapeDiverged(rank: Int, chipClass: ClusterChipClass, cuts: [Int], mode: ClusterGenerationMode, diverged: String)
        /// Public traffic: the model has records, but none of them ran the
        /// installed artifact.
        case artifactNotQualified(installed: String, qualified: [String])
    }
    public let runtimeModelID: String
    public let publicModelID: String
    public let reason: Reason

    public var errorDescription: String? { description }
    public var description: String {
        let model = "This cluster's model, \(publicModelID) (registered as \(runtimeModelID)),"
        let policy = " That is a policy decision about this model, not a fault in the setup, and no cluster setting changes it."
        let owner = " Its owner may still serve it on a pair; public traffic needs a passing cross-cable check."
        switch reason {
        case .noGrant:
            return model + " is not yet qualified for public traffic: no cross-cable qualification record of it has passed. "
                + "A passing run on any Macs qualifies its mode family on any Apple silicon." + owner
        case .withheld(let why):
            return model + " is not qualified for public traffic: \(why)." + owner
        case .noStageAdapter:
            return model + " has no cluster stage adapter in this darkbloom, so no sharded layout (pipeline or tensor parallel) "
                + "can run it across Macs. A Mac that holds it alone serves it with single-Mac Darkbloom." + policy
        case .placementShape(let rank, let rankCount):
            return model + " cannot be placed: rank \(rank) of a placement of \(rankCount) ranks. A pair placement has two or more ranks in order."
        case .unknownChip(let rank, let role):
            return model + " cannot run rank \(rank) (the \(role.words)) on this Mac: its chip is not Apple silicon as the system names it "
                + "(a virtual machine's chip is not), so this build cannot check the rank. "
                + "The chip family and tier are read on the Mac that runs the rank; a kernel capability such as mlx_nax does not make one." + policy
        case .artifactNotQualified(let installed, let qualified):
            return model + " is installed as artifact \(installed.prefix(12)), and its cross-cable qualification records ran "
                + (qualified.isEmpty ? "no artifact" : "only " + qualified.map { String($0.prefix(12)) }.joined(separator: ", "))
                + ", so this artifact is not yet qualified for public traffic; another artifact of the same model (another "
                + "quantization, a re-upload) needs its own passing check." + owner
        case .modeMissing(let rank):
            return model + ": rank \(rank) was checked without its generation mode, and a rank is started only with its mode named." + policy
        case .shapeDiverged(let rank, let chipClass, let cuts, let mode, let diverged):
            return model + " diverged from its single-Mac reference in a cross-cable check at some placements (\(diverged)), and those "
                + "exact shapes are not served. Rank \(rank) of this placement runs on \(chipClass.rawValue) at cut "
                + "\(cuts.map(String.init).joined(separator: "/")) in \(mode.rawValue), which is one of them; the planner picks another cut "
                + "or order on these Macs." + policy
        }
    }
}

extension ClusterPairServingRole {
    var words: String { self == .decodingRank ? "decoding rank" : "pipeline-only rank" }
}

/// The pair-serving decisions a set of qualification records gives, one per
/// registered model that has a record (owner decision D4; "universal
/// mechanisms", 2026-10-11; mode-bound, owner sign-off O9; chip-agnostic,
/// owner 2026-10-14): nothing here names a model, a chip or an order. Each
/// mode family of a model (`ClusterPairServingModeFamily`) is
///
/// - granted when some record of the family passed, on any chips: a pass is
///   evidence for the model, its artifact and that family on any Apple
///   silicon the planner can place it on (a pass that a divergence of the
///   very same shape contradicts is no evidence and grants nothing);
/// - withheld when its records diverged and none passed;
/// - and otherwise (no record, or only inconclusive ones) not granted.
///
/// A diverged record of a granted family withholds only what it ran: its
/// chip combination is served only at shapes a check passed in, and its exact
/// rank-shapes are refused (`ClusterPairQualificationRecords`).
///
/// A model is granted when some family is; withheld when no family is granted
/// and some family diverged; undecided otherwise, which refuses it as having
/// no grant.
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
    /// The records these decisions were made from.
    let records: [ClusterPairQualificationRecord]

    /// The decisions the records of one artifact give: what a pair serving
    /// that artifact may rest on. A record of the same model run on another
    /// artifact (another quantization, or a record labelled with the wrong
    /// model) grants nothing here.
    public func scoped(toArtifact artifactSHA256: String) -> ClusterPairServingDecisions {
        .init(records: records.filter { $0.artifactSHA256 == artifactSHA256 })
    }

    /// The artifacts a model's usable records ran, sorted.
    public func artifacts(runtimeModelID: String) -> [String] {
        Set(records.filter { $0.runtimeModelID == runtimeModelID }.map(\.artifactSHA256)).sorted()
    }

    /// A model's records as shapes; a model with no record restricts none.
    public func shapes(runtimeModelID: String) -> ClusterPairQualificationRecords {
        .init(runtimeModelID: runtimeModelID, passed: passedShapes[runtimeModelID] ?? [], failed: failedShapes[runtimeModelID] ?? [])
    }

    public init(records: [ClusterPairQualificationRecord]) {
        self.records = records
        var passed: [String: [(ClusterPairQualificationRecord, ClusterPairServingQualification)]] = [:]
        var diverged: [String: [(ClusterPairQualificationRecord, [ClusterChipClass])]] = [:]
        var ignored = 0
        for record in records {
            let classes = record.ranks.compactMap { ClusterChipClass(chipName: $0.chip) }
            guard record.isConsistent, classes.count == record.ranks.count, let mode = record.mode else { ignored += 1; continue }
            switch record.outcome {
            case .passed:
                passed[record.runtimeModelID, default: []].append((record, .init(chipClasses: classes, cuts: record.cuts, mode: mode)))
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
        passedShapes = passed.mapValues { unique($0.map(\.1)) }
        failedShapes = diverged.mapValues { runs in
            unique(runs.compactMap { record, classes in record.mode.map { .init(chipClasses: classes, cuts: record.cuts, mode: $0) } })
        }
        // A pass contradicted by a divergence of the same shape (chips in rank order, cuts, mode family) is no
        // evidence for anything: it grants nothing, and the divergence stands.
        let contradicted = { (model: String, run: ClusterPairServingQualification) -> Bool in
            (diverged[model] ?? []).contains { record, classes in
                classes == run.chipClasses && record.cuts == run.cuts && record.mode?.servingFamily == run.family
            }
        }
        var granted: [ClusterPairServingGrant] = []
        for model in passed.keys.sorted() {
            let evidence = (passed[model] ?? []).filter { !contradicted(model, $0.1) }
            guard !evidence.isEmpty else { continue }
            let runs = unique(evidence.map(\.1)).sorted {
                Self.order($0.cuts, $0.mode.rawValue, $0.chipClasses) < Self.order($1.cuts, $1.mode.rawValue, $1.chipClasses)
            }
            let passedFamilies = Set(runs.map(\.family))
            // A family withheld as a whole: it diverged and nothing of it passed.
            let closed = Dictionary(grouping: (diverged[model] ?? []).filter { !passedFamilies.contains($0.0.mode!.servingFamily) }) {
                $0.0.mode!.servingFamily
            }.mapValues { Self.withholding($0) }
            granted.append(ClusterPairServingGrant(runtimeModelID: model, qualifications: runs,
                evidence: Self.evidence(records: evidence.count, placements: runs), withheldFamilies: closed))
        }
        self.granted = granted
        // A model is withheld as a whole only when no family of it is granted.
        let grantedModels = Set(granted.map(\.runtimeModelID))
        withheld = diverged.filter { !grantedModels.contains($0.key) }.mapValues { Self.withholding($0) }
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
        let families = Set(placements.map(\.family)).sorted().map(\.description).joined(separator: ", ")
        return "\(records) passing cross-cable qualification record\(records == 1 ? "" : "s") (near-tie rule against single-Mac references): "
            + orders.joined(separator: "; ") + "; cuts \(cuts); modes \(modes); granted mode families \(families), on any Apple silicon"
    }

    /// Why a model whose records diverged is withheld: the first divergence
    /// (lowest cut, then mode) in full, and every cut that diverged.
    static func withholding(_ runs: [(ClusterPairQualificationRecord, [ClusterChipClass])]) -> String {
        let ordered = runs.sorted { order($0.0.cuts, $0.0.generationMode, $0.1) < order($1.0.cuts, $1.0.generationMode, $1.1) }
        let cuts = Array(Set(ordered.flatMap { $0.0.cuts })).sorted().map(String.init)
        let cutWords = cuts.count == 1 ? "cut \(cuts[0])" : "cuts " + cuts.dropLast().joined(separator: ", ") + " and " + cuts.last!
        guard let (record, classes) = ordered.first, let failure = record.firstFailure else {
            return "its cross-cable check diverged at \(cutWords) and no passing check of it stands"
        }
        var detail = "its cross-cable check diverged at \(cutWords) and no passing check of it stands (first: \(placementWords(classes)), cut \(record.cuts.map(String.init).joined(separator: ",")), "
            + "\(record.generationMode), \(record.promptTokens)-token request"
        if let index = failure.firstDivergenceIndex { detail += ", output \(index)" }
        if let gap = failure.gapInULPs {
            detail += String(format: ", %.1f ulp from the reference's choice against a near-tie threshold of %.1f", gap, failure.nearTieThresholdULPs)
        }
        if let chip = failure.referenceChip { detail += ", against the single-Mac reference recorded on an \(chip)" }
        return detail + ")"
    }
}

/// What a pair serves (owner, 2026-10-14 08:45). For the owner: any model a
/// cluster stage adapter runs, in any sharded mode the runtime has, on any
/// Apple silicon (`ownerServing`, `requireRank`, `plannable`,
/// `startRefusal`), away from the exact shapes a record diverged at; memory
/// is the planner's and each Mac's load gate's. For public traffic: the
/// grants this darkbloom derives from the qualification records it ships
/// (`grant`; `ClusterPairQualificationRecordsBundled`, written by
/// `darkbloom-cluster-pair-check record` from cross-cable runs and their
/// single-Mac references), with the coordinator's parity qualification
/// deciding each placement. The near-tie rule decides each record
/// (`acceptedCrossClassVerdicts`), `ClusterPairServingDecisions` decides each
/// model. Single-Mac serving requirements (`ModelRuntimeRequirements`) are
/// separate and unchanged. No chip is listed anywhere.
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
    /// Registered models whose records diverged and none passed, and why.
    public static var withheld: [String: String] { decisions.withheld }

    /// The artifact a record of `runtimeModelID` must have run for an
    /// installed capability whose artifact is `installed`: the same digest.
    /// Only a check built from these sources with
    /// `DARKBLOOM_CLUSTER_FIXTURE_ARTIFACTS` (never a product build) can name
    /// the registered artifact a fixture's own files stand for.
    static func qualifyingArtifact(for installed: String, runtimeModelID: String) -> String {
#if DARKBLOOM_CLUSTER_FIXTURE_ARTIFACTS
        return fixtureArtifacts.withLock { $0[fixtureKey(installed, runtimeModelID)] } ?? installed
#else
        return installed
#endif
    }

#if DARKBLOOM_CLUSTER_FIXTURE_ARTIFACTS
    /// Check builds only: (fixture artifact, model) -> the registered artifact it stands for.
    public static let fixtureArtifacts = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    public static func fixtureKey(_ installed: String, _ runtimeModelID: String) -> String { runtimeModelID + "|" + installed }
#endif

    /// `decisions` narrowed to the records of the installed artifact, when one
    /// is given; nil keeps every record (a plan read from profiles only).
    static func decisions(_ decisions: ClusterPairServingDecisions, artifactSHA256: String?,
                          runtimeModelID: String) -> ClusterPairServingDecisions {
        artifactSHA256.map { decisions.scoped(toArtifact: qualifyingArtifact(for: $0, runtimeModelID: runtimeModelID)) } ?? decisions
    }

    /// Every check of a model on record, passed and failed, in each
    /// qualification's shape, from the bundled records
    /// (`ClusterPairServingDecisions.shapes`), of the installed artifact when
    /// one is given.
    public static func records(runtimeModelID: String, artifactSHA256: String? = nil,
                               decisions: ClusterPairServingDecisions = decisions) -> ClusterPairQualificationRecords {
        Self.decisions(decisions, artifactSHA256: artifactSHA256, runtimeModelID: runtimeModelID).shapes(runtimeModelID: runtimeModelID)
    }

    /// The decode speed-up a pipeline's speculative rounds (`pipeline_mtp_v1`)
    /// are credited with before this pair has served them: the smallest that
    /// the installed artifact's passing records of the rounds measured over the
    /// plain pipeline of their placement
    /// (`ClusterPairQualificationRecord.measuredPipelineSpeculativeSpeedup`).
    /// Nil unless the model is granted the `pipeline_speculative` family (a
    /// diverged record withholds it, and then nothing is credited) and some
    /// passing record measured it. The planner credits it only where the
    /// decoding rank has no served measurement of its own.
    public static func recordedPipelineSpeculativeFactor(runtimeModelID: String, artifactSHA256: String? = nil,
                                                         decisions: ClusterPairServingDecisions = decisions) -> Double? {
        let scoped = Self.decisions(decisions, artifactSHA256: artifactSHA256, runtimeModelID: runtimeModelID)
        guard let grant = scoped.granted.first(where: { $0.runtimeModelID == runtimeModelID }),
              grant.families.contains(.pipelineSpeculative), grant.withheldFamilies[.pipelineSpeculative] == nil else { return nil }
        return scoped.records.filter { $0.runtimeModelID == runtimeModelID }
            .compactMap(\.measuredPipelineSpeculativeSpeedup).filter { $0.isFinite && $0 > 0 }.min()
    }

    /// The PUBLIC grant: the mode families a model's passing records qualify
    /// for public traffic (the coordinator's parity qualification still decides
    /// each placement); a refusal for every other model. With `artifactSHA256`
    /// (the installed capability's), only the records of that artifact count.
    /// This never decides whether the owner may serve the model
    /// (`ownerServing`).
    public static func grant(runtimeModelID: String, publicModelID: String, artifactSHA256: String? = nil,
                             decisions: ClusterPairServingDecisions = decisions) throws -> ClusterPairServingGrant {
        let scoped = Self.decisions(decisions, artifactSHA256: artifactSHA256, runtimeModelID: runtimeModelID)
        if let grant = scoped.granted.first(where: { $0.runtimeModelID == runtimeModelID }) { return grant }
        if let why = scoped.withheld[runtimeModelID] {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: .withheld(why))
        }
        let ran = decisions.artifacts(runtimeModelID: runtimeModelID)
        if let artifactSHA256, !ran.isEmpty {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
                reason: .artifactNotQualified(installed: artifactSHA256, qualified: ran))
        }
        throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: .noGrant)
    }

    /// Whether a cluster stage adapter of this build runs the model: every
    /// adapter runs the pipeline (a capability record lists it first), so a
    /// registered model always has a sharded mode.
    public static func hasStageAdapter(runtimeModelID: String) -> Bool {
        ClusterRuntimeAdapter.registering(runtimeModelID: runtimeModelID) != nil
    }

    static func requireStageAdapter(runtimeModelID: String, publicModelID: String) throws {
        guard hasStageAdapter(runtimeModelID: runtimeModelID) else {
            throw ClusterPairServingRefusal(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: .noStageAdapter)
        }
    }

    /// The owner's own serving of a model (owner, 2026-10-14 08:45): refused
    /// only when no cluster stage adapter runs it; memory is the planner's and
    /// each Mac's load gate's. Records add the public grant, if any, and the
    /// shapes the planner steers away from.
    public static func ownerServing(runtimeModelID: String, publicModelID: String, artifactSHA256: String? = nil,
                                    decisions: ClusterPairServingDecisions = decisions) throws -> ClusterPairOwnerServing {
        try requireStageAdapter(runtimeModelID: runtimeModelID, publicModelID: publicModelID)
        return .init(runtimeModelID: runtimeModelID,
            publicGrant: try? grant(runtimeModelID: runtimeModelID, publicModelID: publicModelID, artifactSHA256: artifactSHA256,
                                    decisions: decisions),
            records: records(runtimeModelID: runtimeModelID, artifactSHA256: artifactSHA256, decisions: decisions))
    }

    /// The one line a plan or the onboarding shows about public traffic for a
    /// model served in `mode`.
    public static func publicTrafficLine(runtimeModelID: String, artifactSHA256: String? = nil, mode: ClusterGenerationMode?,
                                         decisions: ClusterPairServingDecisions = decisions) -> String {
        let grant = try? grant(runtimeModelID: runtimeModelID, publicModelID: runtimeModelID, artifactSHA256: artifactSHA256,
                               decisions: decisions)
        return ClusterPairOwnerServing.publicTrafficLine(grant: grant, mode: mode)
    }

    /// One rank of a placement, checked on the Mac that runs it with that
    /// Mac's own chip class, for the owner's serving: any Apple silicon runs
    /// any rank of any sharded mode the model's stage adapter has, with or
    /// without a record; a rank whose class ran a diverged shape at this rank
    /// refuses that exact shape. Unknown ranks are checked where every rank's
    /// class is known (`startRefusal`, `plannable`, `requirePlacement`).
    public static func requireRank(_ rank: Int, of rankCount: Int, chipClass: ClusterChipClass?,
                                   runtimeModelID: String, publicModelID: String, artifactSHA256: String? = nil,
                                   cuts: [Int]? = nil, mode: ClusterGenerationMode? = nil,
                                   decisions: ClusterPairServingDecisions = decisions) throws {
        try requireStageAdapter(runtimeModelID: runtimeModelID, publicModelID: publicModelID)
        func refuse(_ reason: ClusterPairServingRefusal.Reason) -> ClusterPairServingRefusal {
            .init(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: reason)
        }
        guard let role = ClusterPairServingRole.of(rank: rank, rankCount: rankCount) else {
            throw refuse(.placementShape(rank: rank, rankCount: rankCount))
        }
        guard let chipClass else { throw refuse(.unknownChip(rank: rank, role: role)) }
        // A family with a diverged record needs the mode and the placement's
        // shape: a caller that does not give them is refused rather than
        // admitted at a shape that diverged.
        guard let mode else { throw refuse(.modeMissing(rank: rank)) }
        let checks = records(runtimeModelID: runtimeModelID, artifactSHA256: artifactSHA256, decisions: decisions)
        if checks.restricts(mode.servingFamily) {
            guard let cuts, checks.admitsRank(rank, of: rankCount, chipClass: chipClass, cuts: cuts, mode: mode) else {
                throw refuse(.shapeDiverged(rank: rank, chipClass: chipClass, cuts: cuts ?? [], mode: mode, diverged: checks.failedShapesText))
            }
        }
    }

    /// The half of a placement no single rank can check (a rank with no
    /// class): nil, or the refusal for a placement that could be a shape that
    /// diverged.
    static func combinationRefusal(_ rankClasses: [ClusterChipClass?], cuts: [Int], mode: ClusterGenerationMode,
                                   runtimeModelID: String, publicModelID: String, artifactSHA256: String?,
                                   decisions: ClusterPairServingDecisions) -> ClusterPairServingRefusal? {
        let checks = records(runtimeModelID: runtimeModelID, artifactSHA256: artifactSHA256, decisions: decisions)
        guard checks.restricts(mode.servingFamily), !checks.admits(chipClasses: rankClasses, cuts: cuts, mode: mode) else { return nil }
        let rank = rankClasses.count - 1
        guard let last = rankClasses.compactMap({ $0 }).last else { return nil }
        return .init(runtimeModelID: runtimeModelID, publicModelID: publicModelID,
            reason: .shapeDiverged(rank: rank, chipClass: rankClasses[rank] ?? last, cuts: cuts, mode: mode, diverged: checks.failedShapesText))
    }

    /// Whether the planner may consider a placement of this model: the rule a
    /// start applies, from the chip names the profiles carry. Any sharded mode
    /// the runtime lists is planned with or without a record (tensor parallel
    /// included); only a shape that diverged on these chips is left out
    /// (`ClusterPairQualificationRecords.admits`). A model no stage adapter
    /// runs is never planned.
    public static func plannable(_ rankClasses: [ClusterChipClass?], cuts: [Int], mode: ClusterGenerationMode,
                                 runtimeModelID: String, artifactSHA256: String? = nil,
                                 decisions: ClusterPairServingDecisions = decisions) -> Bool {
        guard hasStageAdapter(runtimeModelID: runtimeModelID) else { return false }
        let checks = records(runtimeModelID: runtimeModelID, artifactSHA256: artifactSHA256, decisions: decisions)
        return !checks.restricts(mode.servingFamily) || checks.admits(chipClasses: rankClasses, cuts: cuts, mode: mode)
    }

    /// What the owner's start would refuse of a planned placement (each rank's
    /// chip class in rank order, its cuts and mode), nil when every rank's own
    /// check and the combination check admit it. The onboarding offers a model
    /// only when this is nil, so it offers exactly what a start serves. A rank
    /// whose chip has no class (a test profile, a virtual machine) is left to
    /// its own start, as in `plannable`.
    public static func startRefusal(_ rankClasses: [ClusterChipClass?], cuts: [Int], mode: ClusterGenerationMode,
                                    runtimeModelID: String, publicModelID: String, artifactSHA256: String? = nil,
                                    decisions: ClusterPairServingDecisions = decisions) -> ClusterPairServingRefusal? {
        do {
            try requireStageAdapter(runtimeModelID: runtimeModelID, publicModelID: publicModelID)
            for (rank, chipClass) in rankClasses.enumerated() where chipClass != nil {
                try requireRank(rank, of: rankClasses.count, chipClass: chipClass, runtimeModelID: runtimeModelID,
                                publicModelID: publicModelID, artifactSHA256: artifactSHA256, cuts: cuts, mode: mode,
                                decisions: decisions)
            }
            return combinationRefusal(rankClasses, cuts: cuts, mode: mode, runtimeModelID: runtimeModelID,
                                      publicModelID: publicModelID, artifactSHA256: artifactSHA256, decisions: decisions)
        } catch let refusal as ClusterPairServingRefusal {
            return refusal
        } catch {
            return .init(runtimeModelID: runtimeModelID, publicModelID: publicModelID, reason: .noStageAdapter)
        }
    }

    /// A whole placement for the owner: each rank's chip class in rank order.
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
        if let cuts, let mode, let refusal = combinationRefusal(rankClasses, cuts: cuts, mode: mode, runtimeModelID: runtimeModelID,
                                                                publicModelID: publicModelID, artifactSHA256: nil, decisions: decisions) {
            throw refusal
        }
    }
}

/// A model its owner may serve on a pair (owner, 2026-10-14 08:45: detect ->
/// pick a model -> memory check -> the planner picks tensor parallel or
/// pipeline). Whether the two Macs can hold it is the planner's; this carries
/// what the records add: the public grant, if any (the coordinator still
/// requires its parity qualification for each placement), and the shapes
/// that diverged, which the planner steers away from.
public struct ClusterPairOwnerServing: Sendable, Equatable {
    /// The one line shown for a model or placement with no public grant.
    public static let notYetQualified = "not yet qualified for public traffic"

    public let runtimeModelID: String
    /// The records' public grant; nil when no passing record of the installed
    /// artifact stands.
    public let publicGrant: ClusterPairServingGrant?
    /// Every check on record, for the shapes they steer away from.
    public let records: ClusterPairQualificationRecords

    /// The model's public status in one line, whatever the mode.
    public var publicTrafficLine: String { Self.publicTrafficLine(grant: publicGrant, mode: nil) }

    /// The public status of serving it in `mode`, in one line.
    public func publicTrafficLine(mode: ClusterGenerationMode?) -> String { Self.publicTrafficLine(grant: publicGrant, mode: mode) }

    static func publicTrafficLine(grant: ClusterPairServingGrant?, mode: ClusterGenerationMode?) -> String {
        guard let grant, !grant.families.isEmpty, mode.map({ grant.families.contains($0.servingFamily) }) ?? true else {
            return notYetQualified
        }
        let families = (mode.map { [$0.servingFamily] } ?? grant.families).map(\.description).joined(separator: " and ")
        return "qualified for public traffic in \(families) mode (the coordinator's parity qualification decides each placement)"
    }
}
