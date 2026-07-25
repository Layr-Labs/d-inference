import Foundation

/// Gate G2 — "is paged at parity with contiguous?" — as a machine-checkable
/// artifact.
///
/// G2's bar, from the migration plan: MTP token-exact, vision serving, packed
/// prefill active, prefix reuse >= contiguous. Nothing in the tree answered
/// that question end to end against a real model: the engine's differential
/// oracle is unit-scope, the live parity suite compares TEXT on gpt-oss only,
/// and neither reports a per-criterion verdict a release decision can read.
///
/// This file is the verdict half and is deliberately free of MLX, of the
/// engine, and of any model: it turns two `BackendParityObservation` values
/// (one per KV backend, produced by `BackendParityHarness`) into per-criterion
/// PASS / FAIL / UNAVAILABLE plus a process exit status. That split is what
/// makes the gate logic testable without 15 GB of weights.
///
/// Three rules the honesty of this gate rests on, each learned from a bug
/// shipped earlier in this wave:
///
///  1. A criterion that could not be evaluated reports `.unavailable` WITH the
///     missing prerequisite. It never reports `.pass` by default.
///  2. `.unavailable` is not success. A run where every criterion was skipped
///     exits non-zero and with a DIFFERENT status than a run that failed, so
///     "the gate is green" cannot be confused with "the gate never ran".
///  3. Verdicts are keyed on the RESOLVED backend, never the requested one. A
///     `.paged` selection that degraded to contiguous compares contiguous with
///     contiguous and must say so instead of reporting parity with itself.
public struct BackendParityReport: Codable, Sendable {

    /// Bumped when the JSON shape changes so downstream parsers can gate.
    public static let currentSchemaVersion = 1

    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case pass = "PASS"
        case fail = "FAIL"
        case unavailable = "UNAVAILABLE"
    }

    /// Stable criterion identifiers. Scripts key off these, not the titles.
    public enum CriterionID: String, Codable, Sendable, CaseIterable {
        case tokenExactness = "token_exactness"
        case mtpTokenExactness = "mtp_token_exactness"
        case packedPrefill = "packed_prefill"
        case visionSpans = "vision_spans"
        case prefixReuse = "prefix_reuse"
    }

    /// One G2 criterion and everything a reader needs to trust the verdict.
    public struct Criterion: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let verdict: Verdict
        /// PASS/FAIL: the measured evidence. UNAVAILABLE: the exact missing
        /// prerequisite — never a vague "skipped".
        public let detail: String
        /// Per-arm measured facts, keyed by the RESOLVED backend name (or by
        /// `"<selection> (unresolved)"` when construction failed).
        public let measurements: [String: String]

        public init(
            id: CriterionID,
            title: String,
            verdict: Verdict,
            detail: String,
            measurements: [String: String] = [:]
        ) {
            self.id = id.rawValue
            self.title = title
            self.verdict = verdict
            self.detail = detail
            self.measurements = measurements
        }
    }

    /// What one requested backend actually became.
    public struct Arm: Codable, Sendable, Equatable {
        /// What the operator asked for.
        public let selection: String
        /// What the factory actually built. Nil when construction failed.
        public let resolvedBackend: String?
        /// Non-nil when a paged selection DEGRADED to contiguous.
        public let fallbackReason: String?
        /// Verbatim construction error when no engine was built at all.
        public let constructionFailure: String?

        public init(
            selection: String,
            resolvedBackend: String?,
            fallbackReason: String?,
            constructionFailure: String?
        ) {
            self.selection = selection
            self.resolvedBackend = resolvedBackend
            self.fallbackReason = fallbackReason
            self.constructionFailure = constructionFailure
        }
    }

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    /// The MTP assistant, when one was supplied. Nil means MTP was not run.
    public let assistantModelID: String?
    public let arms: [Arm]
    public let criteria: [Criterion]
    public let notes: [String]

    public init(
        schemaVersion: Int = BackendParityReport.currentSchemaVersion,
        modelID: String,
        modelPath: String,
        assistantModelID: String? = nil,
        arms: [Arm],
        criteria: [Criterion],
        notes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelPath = modelPath
        self.assistantModelID = assistantModelID
        self.arms = arms
        self.criteria = criteria
        self.notes = notes
    }

    public var outcome: BackendParityOutcome { BackendParityOutcome(criteria: criteria) }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Operator-facing table. Written to stderr beside the JSON so a human
    /// reading a terminal and a script parsing stdout both get what they need.
    public func renderTable() -> String {
        var lines: [String] = []
        lines.append("gate G2 — paged/contiguous parity: \(modelID)")
        for arm in arms {
            let resolved = arm.resolvedBackend ?? "NOT BUILT"
            var line = "  arm \(arm.selection) -> resolved \(resolved)"
            if let fallback = arm.fallbackReason { line += " (fallback: \(fallback))" }
            if let failure = arm.constructionFailure { line += " — \(failure)" }
            lines.append(line)
        }
        lines.append("")
        for criterion in criteria {
            lines.append("  [\(criterion.verdict.rawValue)] \(criterion.title)")
            lines.append("        \(criterion.detail)")
            for key in criterion.measurements.keys.sorted() {
                lines.append("        \(key): \(criterion.measurements[key] ?? "")")
            }
        }
        lines.append("")
        lines.append("  " + outcome.summary)
        for note in notes { lines.append("  note: \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// The gate's decision, and the only place a process exit status is derived.
///
/// Three states, three statuses. Collapsing "nothing ran" into either of the
/// other two is the failure mode this type exists to prevent: a harness that
/// skipped every criterion has produced no evidence, and evidence-free is not
/// the same as green.
public enum BackendParityOutcome: Equatable, Sendable {
    /// At least one criterion was evaluated and none failed. `skipped` may be
    /// non-zero — the gate passed on what it could measure, and says how much
    /// it could not.
    case passed(evaluated: Int, skipped: Int)
    /// At least one evaluated criterion FAILED. Carries the failing ids.
    case failed(criteria: [String])
    /// Every criterion reported UNAVAILABLE (or there were none at all).
    /// Nothing was measured, so nothing can be concluded.
    case nothingEvaluated(skipped: Int)

    public init(criteria: [BackendParityReport.Criterion]) {
        let failed = criteria.filter { $0.verdict == .fail }.map(\.id)
        let passed = criteria.filter { $0.verdict == .pass }.count
        let skipped = criteria.filter { $0.verdict == .unavailable }.count
        if !failed.isEmpty {
            self = .failed(criteria: failed)
        } else if passed == 0 {
            self = .nothingEvaluated(skipped: skipped)
        } else {
            self = .passed(evaluated: passed, skipped: skipped)
        }
    }

    /// 0 = every evaluated criterion passed. 1 = something failed.
    /// 2 = nothing was evaluated. A gate that exits 0 on total failure — or on
    /// total absence — is not a gate; the sweep benchmark shipped exactly that
    /// bug this wave and it is not repeated here.
    public var exitStatus: Int32 {
        switch self {
        case .passed: return 0
        case .failed: return 1
        case .nothingEvaluated: return 2
        }
    }

    public var summary: String {
        switch self {
        case .passed(let evaluated, 0):
            return "G2 PASS: \(evaluated) criteria evaluated, all passed."
        case .passed(let evaluated, let skipped):
            return "G2 PASS (partial): \(evaluated) criteria passed, "
                + "\(skipped) UNAVAILABLE — the gate is only as strong as what it measured."
        case .failed(let ids):
            return "G2 FAIL: \(ids.joined(separator: ", "))."
        case .nothingEvaluated(let skipped):
            return "G2 INCONCLUSIVE: nothing was evaluated (\(skipped) UNAVAILABLE). "
                + "This is not a pass."
        }
    }
}

// MARK: - Observations (what the live harness measures on ONE backend)

/// Everything `BackendParityHarness` measures on a single KV backend.
///
/// `Codable` so a run can be replayed or diffed offline, and so the criteria
/// evaluation below can be unit-tested against literal values with no model.
public struct BackendParityObservation: Codable, Sendable, Equatable {

    /// One greedy generation.
    public struct Row: Codable, Sendable, Equatable {
        public let prompt: String
        /// RAW sampled token ids, in order. Token EXACTNESS is compared on
        /// this, never on detokenized text: two different id streams can
        /// render to the same string.
        public let tokens: [Int]
        public let finishReason: String

        public init(prompt: String, tokens: [Int], finishReason: String) {
            self.prompt = prompt
            self.tokens = tokens
            self.finishReason = finishReason
        }
    }

    /// MTP arm: the generated rows plus proof the drafter actually ran.
    public struct MTP: Codable, Sendable, Equatable {
        public let rows: [Row]
        /// The engine reported an MTP driver. NOT proof of work: the driver
        /// object existing is what clears `mtpInactiveReason`.
        public let driverConstructed: Bool
        public let inactiveReason: String?
        /// Rounds that drafted (k >= 1) and verified.
        public let rounds: Int
        /// Draft tokens proposed. `rounds > 0 && draftedTokens > 0` is the
        /// only proof drafts were PRODUCED — a constructed-but-inert driver
        /// reports active with all-zero counters, which is exactly the
        /// gemma-4 paged silent no-op this criterion has to catch.
        public let draftedTokens: Int
        public let acceptedTokens: Int
        /// Why rounds never ran: "batch_gate" / "kv_headroom" / "carry_invalid".
        public let skippedRows: [String: Int]
        /// Non-nil when the MTP arm could not be set up at all (no assistant
        /// checkpoint, target not an MTP target, engine refused). Distinct
        /// from an inert drafter, which is a FAIL, not a skip.
        public let unavailableReason: String?

        public init(
            rows: [Row] = [],
            driverConstructed: Bool = false,
            inactiveReason: String? = nil,
            rounds: Int = 0,
            draftedTokens: Int = 0,
            acceptedTokens: Int = 0,
            skippedRows: [String: Int] = [:],
            unavailableReason: String? = nil
        ) {
            self.rows = rows
            self.driverConstructed = driverConstructed
            self.inactiveReason = inactiveReason
            self.rounds = rounds
            self.draftedTokens = draftedTokens
            self.acceptedTokens = acceptedTokens
            self.skippedRows = skippedRows
            self.unavailableReason = unavailableReason
        }

        /// Drafts were genuinely produced, not merely enabled.
        public var producedDrafts: Bool { rounds > 0 && draftedTokens > 0 }
    }

    /// A capability read at RUNTIME against the constructed engine.
    ///
    /// `active == nil` means the harness could not determine it — the reason
    /// is in `detail` and the criterion becomes UNAVAILABLE. Deliberately
    /// tri-state: an advertised-but-unverifiable capability must not collapse
    /// into `false` (a phantom regression) or `true` (a phantom pass).
    public struct Capability: Codable, Sendable, Equatable {
        public let active: Bool?
        public let detail: String

        public init(active: Bool?, detail: String) {
            self.active = active
            self.detail = detail
        }

        public static func undetermined(_ reason: String) -> Capability {
            Capability(active: nil, detail: reason)
        }
    }

    /// Prefix reuse measured by submitting the same prompt twice, in order.
    public struct PrefixReuse: Codable, Sendable, Equatable {
        /// `EngineV2.prefixReuseCapability.isSupported` for this backend and
        /// this layer layout.
        public let capabilitySupported: Bool
        public let capabilityStrategy: String?
        public let capabilityUnsupportedReason: String?
        /// `conservativeReplayBoundTokens`: matched tokens BELOW this are all
        /// replayed, so a match shorter than the bound saves nothing and the
        /// engine reports `skippedPolicy`. Paged pays one extra `maxWindow`
        /// over contiguous by construction, so the two arms have DIFFERENT
        /// bounds and a probe prompt under either one measures nothing.
        public let replayBoundTokens: Int
        /// Length of the probe prompt, so a zero saving can be read against
        /// the bound instead of being mistaken for a regression.
        public let promptTokens: Int
        /// Entries in the cache after waiting for the first request's
        /// donation. Zero means the donation never landed — a harness
        /// problem, not a backend one, and reported as such.
        public let donatedEntries: Int
        /// `CBv2Usage.prefixCacheOutcome` on the first and second submissions.
        public let firstOutcome: String
        public let secondOutcome: String
        public let secondMatchedTokens: Int
        /// The number that matters: prefill tokens the second request did not
        /// have to recompute.
        public let secondPrefillTokensSaved: Int
        public let cacheHits: Int
        public let cacheMisses: Int
        public let cacheTokensSaved: Int
        /// Non-nil when no measurement could be taken at all.
        public let unavailableReason: String?

        public init(
            capabilitySupported: Bool = false,
            capabilityStrategy: String? = nil,
            capabilityUnsupportedReason: String? = nil,
            replayBoundTokens: Int = 0,
            promptTokens: Int = 0,
            donatedEntries: Int = 0,
            firstOutcome: String = "",
            secondOutcome: String = "",
            secondMatchedTokens: Int = 0,
            secondPrefillTokensSaved: Int = 0,
            cacheHits: Int = 0,
            cacheMisses: Int = 0,
            cacheTokensSaved: Int = 0,
            unavailableReason: String? = nil
        ) {
            self.capabilitySupported = capabilitySupported
            self.capabilityStrategy = capabilityStrategy
            self.capabilityUnsupportedReason = capabilityUnsupportedReason
            self.replayBoundTokens = replayBoundTokens
            self.promptTokens = promptTokens
            self.donatedEntries = donatedEntries
            self.firstOutcome = firstOutcome
            self.secondOutcome = secondOutcome
            self.secondMatchedTokens = secondMatchedTokens
            self.secondPrefillTokensSaved = secondPrefillTokensSaved
            self.cacheHits = cacheHits
            self.cacheMisses = cacheMisses
            self.cacheTokensSaved = cacheTokensSaved
            self.unavailableReason = unavailableReason
        }
    }

    /// What was asked for.
    public let selection: String
    /// What was built. Nil when construction failed — every criterion that
    /// depends on this arm then reports UNAVAILABLE.
    public let resolvedBackend: String?
    public let fallbackReason: String?
    public let constructionFailure: String?
    public let rows: [Row]
    public let mtp: MTP?
    public let packedPrefill: Capability
    public let visionSpans: Capability
    public let prefixReuse: PrefixReuse?

    public init(
        selection: String,
        resolvedBackend: String? = nil,
        fallbackReason: String? = nil,
        constructionFailure: String? = nil,
        rows: [Row] = [],
        mtp: MTP? = nil,
        packedPrefill: Capability = .undetermined("not probed"),
        visionSpans: Capability = .undetermined("not probed"),
        prefixReuse: PrefixReuse? = nil
    ) {
        self.selection = selection
        self.resolvedBackend = resolvedBackend
        self.fallbackReason = fallbackReason
        self.constructionFailure = constructionFailure
        self.rows = rows
        self.mtp = mtp
        self.packedPrefill = packedPrefill
        self.visionSpans = visionSpans
        self.prefixReuse = prefixReuse
    }

    /// The name every measurement is filed under. The RESOLVED backend, never
    /// the request — a `.paged` arm that degraded must not be labelled paged.
    public var label: String {
        guard let resolvedBackend else { return "\(selection) (unresolved)" }
        if let fallbackReason { return "\(resolvedBackend) (fallback: \(fallbackReason))" }
        return resolvedBackend
    }

    public var arm: BackendParityReport.Arm {
        BackendParityReport.Arm(
            selection: selection,
            resolvedBackend: resolvedBackend,
            fallbackReason: fallbackReason,
            constructionFailure: constructionFailure)
    }
}

// MARK: - Criteria evaluation

/// Turns two arms into G2's five verdicts. Pure: no MLX, no engine, no model.
public enum BackendParityCriteria {

    /// Evaluate every G2 criterion. `baseline` is the contiguous arm (the
    /// reference the plan measures paged against); `candidate` is the paged
    /// arm.
    public static func evaluate(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> [BackendParityReport.Criterion] {
        [
            tokenExactness(baseline: baseline, candidate: candidate),
            mtpTokenExactness(baseline: baseline, candidate: candidate),
            packedPrefill(baseline: baseline, candidate: candidate),
            visionSpans(baseline: baseline, candidate: candidate),
            prefixReuse(baseline: baseline, candidate: candidate),
        ]
    }

    /// The precondition every cross-backend criterion shares: two arms that
    /// both built, and that built DIFFERENT backends. Returns the blocking
    /// reason, or nil when the comparison is meaningful.
    ///
    /// The same-backend check is not pedantry. A kill-switched `.paged`
    /// selection degrades to contiguous, and comparing contiguous against
    /// contiguous passes every criterion while proving nothing about paged.
    static func comparisonBlocker(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> String? {
        if let failure = baseline.constructionFailure {
            return "the \(baseline.selection) arm built no engine: \(failure)"
        }
        if let failure = candidate.constructionFailure {
            return "the \(candidate.selection) arm built no engine: \(failure)"
        }
        guard let baseKind = baseline.resolvedBackend else {
            return "the \(baseline.selection) arm reported no resolved backend"
        }
        guard let candidateKind = candidate.resolvedBackend else {
            return "the \(candidate.selection) arm reported no resolved backend"
        }
        if baseKind == candidateKind {
            return "both arms resolved to \(baseKind)"
                + (candidate.fallbackReason.map { " (fallback: \($0))" } ?? "")
                + " — no cross-backend comparison was performed"
        }
        return nil
    }

    // MARK: token exactness

    static func tokenExactness(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> BackendParityReport.Criterion {
        let title = "token exactness: greedy decode produces IDENTICAL token ids on both backends"
        let id = BackendParityReport.CriterionID.tokenExactness

        if let blocker = comparisonBlocker(baseline: baseline, candidate: candidate) {
            return .init(id: id, title: title, verdict: .unavailable, detail: blocker)
        }
        if baseline.rows.isEmpty || candidate.rows.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "no greedy rows were generated "
                    + "(\(baseline.label): \(baseline.rows.count), "
                    + "\(candidate.label): \(candidate.rows.count))")
        }

        var measurements: [String: String] = [
            baseline.label: tokenSummary(baseline.rows),
            candidate.label: tokenSummary(candidate.rows),
        ]

        if let mismatch = rowMismatch(baseline: baseline.rows, candidate: candidate.rows) {
            measurements["divergence"] = mismatch
            return .init(
                id: id, title: title, verdict: .fail,
                detail: "\(candidate.label) diverged from \(baseline.label): \(mismatch)",
                measurements: measurements)
        }

        let total = baseline.rows.reduce(0) { $0 + $1.tokens.count }
        return .init(
            id: id, title: title, verdict: .pass,
            detail: "\(baseline.rows.count) prompts, \(total) generated token ids identical "
                + "between \(baseline.label) and \(candidate.label), finish reasons equal",
            measurements: measurements)
    }

    // MARK: MTP

    static func mtpTokenExactness(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> BackendParityReport.Criterion {
        let title = "MTP: drafts PRODUCED on both backends and token ids identical"
        let id = BackendParityReport.CriterionID.mtpTokenExactness

        if let blocker = comparisonBlocker(baseline: baseline, candidate: candidate) {
            return .init(id: id, title: title, verdict: .unavailable, detail: blocker)
        }
        guard let base = baseline.mtp else {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "MTP was not run on \(baseline.label) (no drafter supplied)")
        }
        guard let cand = candidate.mtp else {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "MTP was not run on \(candidate.label) (no drafter supplied)")
        }
        if let reason = base.unavailableReason {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "MTP could not be set up on \(baseline.label): \(reason)")
        }
        if let reason = cand.unavailableReason {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "MTP could not be set up on \(candidate.label): \(reason)")
        }

        let measurements: [String: String] = [
            baseline.label: mtpSummary(base),
            candidate.label: mtpSummary(cand),
        ]

        // Drafts-produced comes FIRST. A no-op drafter emits the target's own
        // tokens, so the token comparison below would pass on nothing.
        var inert: [String] = []
        if !base.producedDrafts { inert.append(baseline.label) }
        if !cand.producedDrafts { inert.append(candidate.label) }
        if !inert.isEmpty {
            return .init(
                id: id, title: title, verdict: .fail,
                detail: "MTP produced no drafts on \(inert.joined(separator: " and ")) — "
                    + "a silent no-op trivially matches the baseline, so token equality "
                    + "proves nothing here",
                measurements: measurements)
        }

        if base.rows.isEmpty || cand.rows.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "drafts were produced but no MTP rows were captured "
                    + "(\(baseline.label): \(base.rows.count), \(candidate.label): \(cand.rows.count))",
                measurements: measurements)
        }

        if let mismatch = rowMismatch(baseline: base.rows, candidate: cand.rows) {
            var failed = measurements
            failed["divergence"] = mismatch
            return .init(
                id: id, title: title, verdict: .fail,
                detail: "MTP output diverged: \(mismatch)",
                measurements: failed)
        }

        return .init(
            id: id, title: title, verdict: .pass,
            detail: "both backends drafted (\(base.draftedTokens) and \(cand.draftedTokens) "
                + "draft tokens over \(base.rounds) and \(cand.rounds) rounds) and produced "
                + "identical token ids across \(base.rows.count) prompts",
            measurements: measurements)
    }

    // MARK: capabilities

    static func packedPrefill(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> BackendParityReport.Criterion {
        capability(
            id: .packedPrefill,
            title: "packed prefill ACTIVE on both backends",
            baseline: baseline,
            candidate: candidate,
            probe: \.packedPrefill)
    }

    static func visionSpans(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> BackendParityReport.Criterion {
        capability(
            id: .visionSpans,
            title: "vision spans ACTIVE on both backends",
            baseline: baseline,
            candidate: candidate,
            probe: \.visionSpans)
    }

    private static func capability(
        id: BackendParityReport.CriterionID,
        title: String,
        baseline: BackendParityObservation,
        candidate: BackendParityObservation,
        probe: KeyPath<BackendParityObservation, BackendParityObservation.Capability>
    ) -> BackendParityReport.Criterion {
        if let blocker = comparisonBlocker(baseline: baseline, candidate: candidate) {
            return .init(id: id, title: title, verdict: .unavailable, detail: blocker)
        }
        let base = baseline[keyPath: probe]
        let cand = candidate[keyPath: probe]
        let measurements: [String: String] = [
            baseline.label: capabilitySummary(base),
            candidate.label: capabilitySummary(cand),
        ]
        // Undetermined on EITHER arm makes the comparison meaningless. Do not
        // silently downgrade to "the one we could read".
        var undetermined: [String] = []
        if base.active == nil { undetermined.append("\(baseline.label): \(base.detail)") }
        if cand.active == nil { undetermined.append("\(candidate.label): \(cand.detail)") }
        if !undetermined.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: undetermined.joined(separator: "; "),
                measurements: measurements)
        }
        var inactive: [String] = []
        if base.active == false { inactive.append("\(baseline.label): \(base.detail)") }
        if cand.active == false { inactive.append("\(candidate.label): \(cand.detail)") }
        if !inactive.isEmpty {
            return .init(
                id: id, title: title, verdict: .fail,
                detail: "not active on " + inactive.joined(separator: "; "),
                measurements: measurements)
        }
        return .init(
            id: id, title: title, verdict: .pass,
            detail: "active on \(baseline.label) and \(candidate.label)",
            measurements: measurements)
    }

    // MARK: prefix reuse

    static func prefixReuse(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> BackendParityReport.Criterion {
        let title = "prefix reuse: paged saves at least as many prefill tokens as contiguous"
        let id = BackendParityReport.CriterionID.prefixReuse

        if let blocker = comparisonBlocker(baseline: baseline, candidate: candidate) {
            return .init(id: id, title: title, verdict: .unavailable, detail: blocker)
        }
        guard let base = baseline.prefixReuse else {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "prefix reuse was not measured on \(baseline.label)")
        }
        guard let cand = candidate.prefixReuse else {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "prefix reuse was not measured on \(candidate.label)")
        }
        if let reason = base.unavailableReason {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "prefix reuse could not be measured on \(baseline.label): \(reason)")
        }
        if let reason = cand.unavailableReason {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "prefix reuse could not be measured on \(candidate.label): \(reason)")
        }

        let measurements: [String: String] = [
            baseline.label: prefixSummary(base),
            candidate.label: prefixSummary(cand),
        ]

        // The first request's donation never landed, so the second request had
        // nothing to match. That is the HARNESS failing to set the experiment
        // up, not the backend failing to reuse, and calling it a regression
        // would be a fabricated finding.
        var undonated: [String] = []
        if base.donatedEntries == 0 { undonated.append(baseline.label) }
        if cand.donatedEntries == 0 { undonated.append(candidate.label) }
        if !undonated.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "no prefix was donated to the cache on "
                    + undonated.joined(separator: " and ")
                    + ", so the second request had nothing to match — the probe never ran",
                measurements: measurements)
        }

        // A match shorter than the frozen-replay bound is fully replayed and
        // saves nothing, so a probe prompt under either arm's bound measures
        // the prompt length, not the backend. Paged's bound is one maxWindow
        // above contiguous's BY CONSTRUCTION, so the two differ and the
        // larger one governs.
        let bound = max(base.replayBoundTokens, cand.replayBoundTokens)
        let promptTokens = max(base.promptTokens, cand.promptTokens)
        if base.secondPrefillTokensSaved == 0, cand.secondPrefillTokensSaved == 0,
            bound > 0, promptTokens <= bound
        {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "the \(promptTokens)-token probe prompt is at or below the "
                    + "frozen-replay bound (\(baseline.label) \(base.replayBoundTokens), "
                    + "\(candidate.label) \(cand.replayBoundTokens)), so no saving is "
                    + "reachable at this length — raise --parity-prefix-tokens above "
                    + "\(bound)",
                measurements: measurements)
        }

        // Neither backend reused anything. `paged >= contiguous` is TRUE here
        // and utterly vacuous — the workload never exercised the cache, so
        // reporting PASS would launder a non-measurement into evidence.
        if base.secondPrefillTokensSaved == 0 && cand.secondPrefillTokensSaved == 0 {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "neither backend reused a prefix (0 prefill tokens saved on both) — "
                    + "the comparison is vacuous, not a pass",
                measurements: measurements)
        }

        if cand.secondPrefillTokensSaved < base.secondPrefillTokensSaved {
            var detail = "\(candidate.label) saved \(cand.secondPrefillTokensSaved) prefill "
                + "tokens against \(base.secondPrefillTokensSaved) on \(baseline.label)"
            if !cand.capabilitySupported, let reason = cand.capabilityUnsupportedReason {
                detail += " — the backend's prefix-reuse capability is unsupported: \(reason)"
            }
            return .init(
                id: id, title: title, verdict: .fail, detail: detail,
                measurements: measurements)
        }

        return .init(
            id: id, title: title, verdict: .pass,
            detail: "\(candidate.label) saved \(cand.secondPrefillTokensSaved) prefill tokens, "
                + ">= \(base.secondPrefillTokensSaved) on \(baseline.label)",
            measurements: measurements)
    }

    // MARK: - Comparators

    /// First per-row divergence between two token-id streams, or nil when
    /// every row matches exactly (ids AND finish reason).
    static func rowMismatch(
        baseline: [BackendParityObservation.Row],
        candidate: [BackendParityObservation.Row]
    ) -> String? {
        guard baseline.count == candidate.count else {
            return "row count differs: \(baseline.count) vs \(candidate.count)"
        }
        for (base, cand) in zip(baseline, candidate) {
            guard base.prompt == cand.prompt else {
                return "prompt order differs: '\(base.prompt)' vs '\(cand.prompt)'"
            }
            if let index = firstDivergence(base.tokens, cand.tokens) {
                let lhs = base.tokens.count > index ? "\(base.tokens[index])" : "<end>"
                let rhs = cand.tokens.count > index ? "\(cand.tokens[index])" : "<end>"
                return "prompt '\(base.prompt)' token \(index): \(lhs) vs \(rhs) "
                    + "(lengths \(base.tokens.count) vs \(cand.tokens.count))"
            }
            if base.finishReason != cand.finishReason {
                return "prompt '\(base.prompt)' finish reason: "
                    + "\(base.finishReason) vs \(cand.finishReason)"
            }
        }
        return nil
    }

    /// Index of the first differing element, or of the end of the shorter
    /// array when one is a strict prefix of the other. Nil when equal.
    static func firstDivergence(_ lhs: [Int], _ rhs: [Int]) -> Int? {
        let shared = min(lhs.count, rhs.count)
        var index = 0
        while index < shared {
            if lhs[index] != rhs[index] { return index }
            index += 1
        }
        return lhs.count == rhs.count ? nil : shared
    }

    // MARK: - Summaries

    static func tokenSummary(_ rows: [BackendParityObservation.Row]) -> String {
        let total = rows.reduce(0) { $0 + $1.tokens.count }
        let reasons = Set(rows.map(\.finishReason)).sorted().joined(separator: "/")
        return "\(rows.count) rows, \(total) tokens, finish=\(reasons)"
    }

    static func mtpSummary(_ mtp: BackendParityObservation.MTP) -> String {
        var summary = "driver=\(mtp.driverConstructed), rounds=\(mtp.rounds), "
            + "drafted=\(mtp.draftedTokens), accepted=\(mtp.acceptedTokens), "
            + "rows=\(mtp.rows.count)"
        if let reason = mtp.inactiveReason { summary += ", inactive=\(reason)" }
        if !mtp.skippedRows.isEmpty {
            let skipped = mtp.skippedRows.keys.sorted()
                .map { "\($0)=\(mtp.skippedRows[$0] ?? 0)" }
                .joined(separator: ",")
            summary += ", skipped[\(skipped)]"
        }
        return summary
    }

    static func capabilitySummary(_ capability: BackendParityObservation.Capability) -> String {
        switch capability.active {
        case true: return "ACTIVE — \(capability.detail)"
        case false: return "INACTIVE — \(capability.detail)"
        case nil: return "UNDETERMINED — \(capability.detail)"
        }
    }

    static func prefixSummary(_ reuse: BackendParityObservation.PrefixReuse) -> String {
        var summary = "capability=\(reuse.capabilitySupported ? "supported" : "unsupported")"
        if let strategy = reuse.capabilityStrategy { summary += "(\(strategy))" }
        if let reason = reuse.capabilityUnsupportedReason { summary += "(\(reason))" }
        summary += ", replayBound=\(reuse.replayBoundTokens)"
        summary += ", prompt=\(reuse.promptTokens)"
        summary += ", donated=\(reuse.donatedEntries)"
        summary += ", outcomes=\(reuse.firstOutcome)->\(reuse.secondOutcome)"
        summary += ", matched=\(reuse.secondMatchedTokens)"
        summary += ", saved=\(reuse.secondPrefillTokensSaved)"
        summary += ", cache(hits=\(reuse.cacheHits),misses=\(reuse.cacheMisses),"
        summary += "tokensSaved=\(reuse.cacheTokensSaved))"
        return summary
    }
}
