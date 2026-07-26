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
    /// 2 adds the `EXPECTED_SHORTFALL` verdict.
    public static let currentSchemaVersion = 2

    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case pass = "PASS"
        case fail = "FAIL"
        /// Measured, understood, and NOT parity. Paged pays one `maxWindow`
        /// of extra frozen replay over contiguous by construction, so a
        /// hybrid model can never reach `paged >= contiguous` on prefix
        /// reuse. Reporting that as FAIL forever trains readers to skip the
        /// criterion; reporting it as PASS lets someone conclude the two
        /// backends match, which they do not. It gets its own verdict, and
        /// it carries the magnitude as a PERCENTAGE of the baseline's saving
        /// — the shortfall is 0.5% on a short-window model and 36% on a
        /// long-window one, so the absolute token count hides the thing that
        /// actually varies.
        ///
        /// The allowance is one `maxWindow`, NOT one `maxPrefillChunk`. The
        /// two coincide on neither model measured so far (gemma-4: window
        /// 1024 vs chunk 512; gpt-oss: window 128 vs chunk 512), so writing
        /// it as "one chunk" would mispredict both. The cause is structural,
        /// not tuning: a contiguous frozen row hands attention the cached
        /// keys for the whole chunk, while `PagedLayerCache.prefillKV` hands
        /// it `gather ++ freshly-projected chunk`, so a frozen paged row
        /// emits poisoned keys inside the current chunk and its replay has
        /// to start one cone earlier.
        ///
        /// Does NOT make the process exit non-zero on its own, but it is
        /// named in the summary line so a reader who only sees the tail of a
        /// CI log cannot miss it.
        case expectedShortfall = "EXPECTED_SHORTFALL"
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

    /// A SAME-BACKEND control: perturb the candidate backend in a way that
    /// should be numerically irrelevant and see whether the token stream
    /// survives it.
    ///
    /// This is the question a cross-backend token comparison cannot answer
    /// about itself. If the incumbent flips under a benign same-backend
    /// change, then no cross-backend token difference on that model is
    /// attributable to the backend — and that must be established per RUN and
    /// per MODEL, not inherited from a one-off experiment in someone's notes.
    ///
    /// The perturbation is the paged pool dtype (fp16 -> fp32), reachable
    /// only since `DARKBLOOM_CBV2_PAGED_KV_DTYPE` landed. The arm is trusted
    /// ONLY when `ProductionBuild.pagedPoolDType` confirms fp32 actually
    /// served; a silently-ignored knob would otherwise masquerade as
    /// agreement, which is exactly the failure class this gate exists to
    /// catch.
    public struct NumericsControl: Codable, Sendable, Equatable {
        /// What was perturbed, in operator vocabulary.
        public let perturbation: String
        /// nil when the control could not be run at all; `detail` says why.
        /// Deliberately tri-state, like `Capability`.
        public let tokenExact: Bool?
        public let detail: String
        /// First flip against the unperturbed arm, when not exact.
        public let firstFlip: String?

        public init(
            perturbation: String,
            tokenExact: Bool?,
            detail: String,
            firstFlip: String? = nil
        ) {
            self.perturbation = perturbation
            self.tokenExact = tokenExact
            self.detail = detail
            self.firstFlip = firstFlip
        }

        /// Leading clause for `token_exactness`, so the reader meets "the
        /// incumbent also flips here" BEFORE the divergence it explains.
        public var headline: String {
            switch tokenExact {
            case false:
                return "CONTROL SAYS THIS IS NOT A BACKEND DIFFERENCE — \(perturbation) "
                    + "on the SAME backend also flips (\(firstFlip ?? detail)), so a "
                    + "numerically benign change is enough to move these tokens and no "
                    + "cross-backend token comparison on this model is meaningful."
            case true:
                return "CONTROL HELD — \(perturbation) on the SAME backend was token-exact, "
                    + "so this cross-backend difference is NOT explained by benign numerics."
            case nil:
                return "CONTROL NOT RUN (\(detail)), so nothing here distinguishes a backend "
                    + "difference from ordinary numerical drift."
            }
        }
    }

    public let schemaVersion: Int
    public let modelID: String
    public let modelPath: String
    /// The MTP assistant, when one was supplied. Nil means MTP was not run.
    public let assistantModelID: String?
    public let arms: [Arm]
    /// The same-backend numerics control, when one could be run.
    public let numericsControl: NumericsControl?
    public let criteria: [Criterion]
    public let notes: [String]

    public init(
        schemaVersion: Int = BackendParityReport.currentSchemaVersion,
        modelID: String,
        modelPath: String,
        assistantModelID: String? = nil,
        arms: [Arm],
        numericsControl: NumericsControl? = nil,
        criteria: [Criterion],
        notes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelPath = modelPath
        self.assistantModelID = assistantModelID
        self.arms = arms
        self.numericsControl = numericsControl
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
        if let numericsControl {
            lines.append("  control (\(numericsControl.perturbation)): "
                + (numericsControl.tokenExact.map { $0 ? "TOKEN-EXACT" : "NOT token-exact" }
                    ?? "NOT RUN"))
            lines.append("        \(numericsControl.detail)")
        } else {
            // An ABSENT control gets a louder line than a failed one, because
            // absence is the state that shipped: this field was declared,
            // stored and rendered for a whole wave while no call site built
            // one, and `if let` with no else meant the table said NOTHING —
            // indistinguishable, to any reader, from a control that ran and
            // held. Whatever else a G2 table does, it states whether the
            // question was asked.
            lines.append("  control: NOT SUPPLIED")
            lines.append("        no numerics control reached this report, so nothing here "
                + "distinguishes a backend difference from ordinary numerical drift. "
                + "BackendParityHarness always supplies one (UNAVAILABLE with a reason "
                + "when it could not run), so a report without one did not come from a "
                + "live --parity run.")
        }
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
///
/// `EXPECTED_SHORTFALL` is deliberately NOT a fourth state. It is a measured,
/// documented cost rather than a failure, so it does not move the exit status
/// on its own — but it rides along in `passed`/`failed` and is named in the
/// summary line, because a reader who sees only the tail of a CI log must not
/// come away believing the backends matched.
public enum BackendParityOutcome: Equatable, Sendable {
    /// At least one criterion was evaluated and none failed. `skipped` may be
    /// non-zero — the gate passed on what it could measure, and says how much
    /// it could not. `shortfalls` names criteria that came in at exactly the
    /// documented structural cost.
    case passed(evaluated: Int, skipped: Int, shortfalls: [String])
    /// At least one evaluated criterion FAILED. Carries the failing ids.
    case failed(criteria: [String], shortfalls: [String])
    /// Every criterion reported UNAVAILABLE (or there were none at all).
    /// Nothing was measured, so nothing can be concluded.
    case nothingEvaluated(skipped: Int)

    public init(criteria: [BackendParityReport.Criterion]) {
        let failed = criteria.filter { $0.verdict == .fail }.map(\.id)
        let shortfalls = criteria.filter { $0.verdict == .expectedShortfall }.map(\.id)
        let passed = criteria.filter { $0.verdict == .pass }.count
        let skipped = criteria.filter { $0.verdict == .unavailable }.count
        if !failed.isEmpty {
            self = .failed(criteria: failed, shortfalls: shortfalls)
        } else if passed == 0 && shortfalls.isEmpty {
            // A shortfall IS a measurement, so a run consisting only of
            // shortfalls is not "nothing evaluated".
            self = .nothingEvaluated(skipped: skipped)
        } else {
            self = .passed(
                evaluated: passed + shortfalls.count, skipped: skipped,
                shortfalls: shortfalls)
        }
    }

    /// 0 = every evaluated criterion passed or came in at the documented
    /// structural cost. 1 = something failed. 2 = nothing was evaluated.
    /// A gate that exits 0 on total failure — or on total absence — is not a
    /// gate; the sweep benchmark shipped exactly that bug this wave and it is
    /// not repeated here.
    public var exitStatus: Int32 {
        switch self {
        case .passed: return 0
        case .failed: return 1
        case .nothingEvaluated: return 2
        }
    }

    public var summary: String {
        switch self {
        case .passed(let evaluated, let skipped, let shortfalls):
            var line = shortfalls.isEmpty
                ? "G2 PASS: \(evaluated) criteria evaluated, all passed."
                : "G2 PASS with EXPECTED SHORTFALL: \(evaluated) criteria evaluated, "
                    + "\(shortfalls.joined(separator: ", ")) at the documented "
                    + "structural cost (NOT parity)."
            if skipped > 0 {
                line += " \(skipped) UNAVAILABLE — the gate is only as strong as what "
                    + "it measured."
            }
            return line
        case .failed(let ids, let shortfalls):
            var line = "G2 FAIL: \(ids.joined(separator: ", "))."
            if !shortfalls.isEmpty {
                line += " EXPECTED SHORTFALL: \(shortfalls.joined(separator: ", "))."
            }
            return line
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
        /// Per emitted token, the top-1 minus top-2 logprob gap — i.e. how
        /// much slack the argmax had. Softmax is monotone, so this gap IS the
        /// logit gap.
        ///
        /// Without it a cross-backend token difference cannot be attributed:
        /// on a model whose argmax is a near-tie, a numerically BENIGN change
        /// flips the token, and the criterion would blame the backend for
        /// arithmetic. Empty when logprobs were not requested.
        public let margins: [Float]

        public init(
            prompt: String, tokens: [Int], finishReason: String, margins: [Float] = []
        ) {
            self.prompt = prompt
            self.tokens = tokens
            self.finishReason = finishReason
            self.margins = margins
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
        /// How each submission TERMINATED. Recorded because the outcome above
        /// cannot be read on its own: the engine's forced-terminal paths
        /// (`EngineLoopV2.watchdogTick`, `forceFinishStreamsOnShutdownTimeout`)
        /// report the SEEDED usage snapshot rather than the request's real
        /// prefix record, and `CBv2Usage`'s default `prefixCacheOutcome` is
        /// `.disabled`. So a `disabled` here means EITHER "no cache was
        /// configured" OR "this request was force-terminated and its prefix
        /// record was never read" — and only the finish reason separates them.
        public let firstFinishReason: String
        public let secondFinishReason: String
        public let secondMatchedTokens: Int
        /// The number that matters: prefill tokens the second request did not
        /// have to recompute.
        public let secondPrefillTokensSaved: Int
        public let cacheHits: Int
        public let cacheMisses: Int
        public let cacheTokensSaved: Int
        /// Did the ADOPTING submission return the same tokens the cold one
        /// did? Both probe requests submit the SAME prompt at temperature 0,
        /// so under exact adoption the two streams are identical and any
        /// difference is adoption changing the answer.
        ///
        /// Non-nil ONLY when the second submission actually adopted (outcome
        /// `hit`); on a miss there is no adoption to judge and a difference
        /// would mean nondeterminism, which is a different finding. `nil`
        /// therefore means NOT MEASURED and must never be read as exact —
        /// the criterion says so out loud rather than passing quietly.
        public let adoptionTokenExact: Bool?
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
            firstFinishReason: String = "",
            secondFinishReason: String = "",
            secondMatchedTokens: Int = 0,
            secondPrefillTokensSaved: Int = 0,
            cacheHits: Int = 0,
            cacheMisses: Int = 0,
            cacheTokensSaved: Int = 0,
            adoptionTokenExact: Bool? = nil,
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
            self.firstFinishReason = firstFinishReason
            self.secondFinishReason = secondFinishReason
            self.secondMatchedTokens = secondMatchedTokens
            self.secondPrefillTokensSaved = secondPrefillTokensSaved
            self.cacheHits = cacheHits
            self.cacheMisses = cacheMisses
            self.cacheTokensSaved = cacheTokensSaved
            self.adoptionTokenExact = adoptionTokenExact
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
        candidate: BackendParityObservation,
        control: BackendParityReport.NumericsControl? = nil
    ) -> [BackendParityReport.Criterion] {
        [
            tokenExactness(baseline: baseline, candidate: candidate, control: control),
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

    /// Relative precision of the fp16 KV the paged pool stores (11-bit
    /// significand). Derived from the storage dtype, NOT tuned.
    static let fp16RelativeEpsilon: Float = 1.0 / 2048.0

    /// Whether the baseline's argmax at `index` had more slack than the
    /// STORAGE precision — i.e. "was this decision resolvable in fp16 at all".
    ///
    /// Read the scope carefully, because the obvious misreading is wrong.
    /// This does NOT answer "was the perturbation small". The perturbation
    /// that flips these tokens is ULP-scale at its ORIGIN (a storage-order
    /// difference) but is no longer small by the time it reaches the logits:
    /// P1_DivergenceRootCause measured a 3.657 contested-vocabulary delta
    /// against a 0.604 margin at gemma-4's first flip — 6.1x, which is why it
    /// flips — while the prompt that does NOT flip inverts the ratio exactly
    /// as drift predicts (margin 4.508 against a 0.691 delta, 0.15x). Single
    /// layer deltas decay with depth (layers 0-9 give 4.0-9.4, layer 29 alone
    /// gives 0.244), so the arrival magnitude is amplification through 30
    /// residual layers and 240 top-8-of-128 MoE selections, not storage noise.
    ///
    /// So a `resolvable: true` answer means the fp16 cache could represent the
    /// gap, and nothing more. It is reported as context beside the first flip;
    /// it is NEVER the reason the criterion declines to score, which is
    /// unconditional (see `tokenExactness`).
    ///
    /// Returns nil when no margin was captured (logprobs not requested), so a
    /// caller cannot claim slack it did not measure.
    static func argmaxResolvable(
        row: BackendParityObservation.Row, index: Int
    ) -> (resolvable: Bool, margin: Float, floor: Float)? {
        guard index >= 0, index < row.margins.count else { return nil }
        let margin = row.margins[index]
        // Logit scale at that position, approximated by the margin's own
        // order plus unity so a near-zero margin still yields a sane floor.
        let floor = max(1, abs(margin)) * fp16RelativeEpsilon
        return (margin > floor, margin, floor)
    }

    /// Index of the first diverging token across rows, for the margin lookup.
    static func firstDivergingRow(
        baseline: [BackendParityObservation.Row],
        candidate: [BackendParityObservation.Row]
    ) -> (row: BackendParityObservation.Row, index: Int)? {
        guard baseline.count == candidate.count else { return nil }
        for (base, cand) in zip(baseline, candidate) where base.prompt == cand.prompt {
            if let index = firstDivergence(base.tokens, cand.tokens) {
                return (base, index)
            }
        }
        return nil
    }

    // MARK: token exactness

    /// Free-running greedy token exactness, as a PASS-ONLY signal.
    ///
    /// It can confirm parity and it can never accuse. Two independent reasons,
    /// both established by measurement rather than argument:
    ///
    ///  1. The incumbent fails it too. P1_DivergenceRootCause showed
    ///     contiguous-against-CONTIGUOUS diverging on 2 of these same 3
    ///     gemma-4 prompts with no backend involved, purely by moving
    ///     `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` 128 -> 8, an operator-REACHABLE
    ///     knob (investigation committed at 977a5893e). A bar the incumbent
    ///     fails under a REACHABLE configuration cannot judge a challenger.
    ///
    ///     Reachable AND, as of 810d64861, sanctioned. v0.8.0 splits this
    ///     knob by VALUE: `=0` (sub-blocking off) is unsupported for a
    ///     MEMORY reason unrelated to exactness, while a non-default NONZERO
    ///     value such as 128 -> 8 is supported and merely outside the
    ///     measured fleet. The configuration this argument rests on is
    ///     therefore blessed as well as reachable.
    ///
    ///     The argument is still pinned to REACHABILITY rather than to that
    ///     blessing, on purpose: policy moves, code does not. `AttentionV1`
    ///     reads the variable at runtime and accepts any `value >= 0` with
    ///     no version gate. Anchors are the SYMBOLS, not the lines: grep
    ///     `AttentionV1.queryBlockSize` for the env parse, and
    ///     `shouldBlockQueries` for the `queryBlockSize > 0 && L >
    ///     queryBlockSize` predicate that turns blocking on. (:35-41 and
    ///     :48 as of this writing, but that file is under concurrent edit —
    ///     the line numbers are a decaying hint, the symbols are not.)
    ///     An operator CAN stand the incumbent in a
    ///     configuration where it fails this bar, so the bar cannot convict
    ///     a challenger — whether or not a given release blesses it.
    ///
    ///     History, so this is not re-litigated a third time: the original
    ///     wording said "a supported configuration", a blanket ban on the
    ///     knob briefly made that read false, and the ban was then withdrawn
    ///     as wrong in both directions. The reachability framing is kept
    ///     because it survives whichever way policy lands next.
    ///
    ///     Nor would retiring the knob restore this criterion as a FAIL
    ///     gate. The knob is the cheapest DEMONSTRATION of the sensitivity,
    ///     not its cause — the amplification described below is a property
    ///     of gemma-4's attention scale and MoE routing density, and
    ///     paged-vs-contiguous storage-order drift perturbs the same
    ///     decisions. Reason 2 below involves no knob at all.
    ///
    ///     The mechanism is storage-order drift, amplified roughly 1,300x
    ///     relative to gpt-oss by gemma-4's attention scale of 1.0 at head
    ///     dim 256/512 and its MoE routing density, landing on decisions
    ///     whose margins are smaller than the amplified perturbation. NOT
    ///     "ulp-only": ULP-scale is the ORIGIN, not the arrival. At the
    ///     first flip the contested-vocabulary delta is 3.657 against a
    ///     0.604 margin (6.1x, so it flips); the prompt that holds inverts
    ///     that ratio (margin 4.508, delta 0.691, 0.15x).
    ///  2. Past the FIRST flip the comparison is not even well-posed. The two
    ///     arms are then decoding different contexts, so every later position
    ///     compares two unrelated conversations. Only the first flip per row
    ///     is a real observation, which is exactly what `rowMismatch`
    ///     reports — never a "divergence rate".
    ///
    /// So: identical streams PASS, anything else is UNAVAILABLE carrying the
    /// first-flip evidence and the measured argmax slack. It stays a genuine
    /// gate on models whose argmax is stable — gpt-oss passes it outright.
    static func tokenExactness(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation,
        control: BackendParityReport.NumericsControl? = nil
    ) -> BackendParityReport.Criterion {
        let title = "token exactness: greedy decode produces IDENTICAL token ids on both backends"
        let id = BackendParityReport.CriterionID.tokenExactness

        if let blocker = comparisonBlocker(baseline: baseline, candidate: candidate) {
            return .init(id: id, title: title, verdict: .unavailable, detail: blocker)
        }
        // Rows that EXIST but carry no tokens are not evidence. Both arms
        // hitting the same submission failure yields equal-length arrays of
        // EMPTY token streams with equal `submit_error` finish reasons, and
        // `rowMismatch` reports two empty streams as identical — so the PASS
        // branch below would book "the backends agree" off a run that
        // generated nothing. "The arms agreed" and "there was nothing to
        // compare" must never render the same way.
        if let blocker = zeroEvidenceBlocker(
            baselineLabel: baseline.label, baselineRows: baseline.rows,
            candidateLabel: candidate.label, candidateRows: candidate.rows)
        {
            return .init(
                id: id, title: title, verdict: .unavailable, detail: blocker,
                measurements: [
                    baseline.label: tokenSummary(baseline.rows),
                    candidate.label: tokenSummary(candidate.rows),
                ])
        }

        var measurements: [String: String] = [
            baseline.label: tokenSummary(baseline.rows),
            candidate.label: tokenSummary(candidate.rows),
        ]

        if let mismatch = rowMismatch(baseline: baseline.rows, candidate: candidate.rows) {
            measurements["firstFlip"] = mismatch
            if let control {
                measurements["control"] = control.tokenExact.map {
                    $0 ? "TOKEN-EXACT" : "NOT token-exact"
                } ?? "NOT RUN"
            }
            // The control LEADS. A reader must meet "the incumbent also flips
            // here" before the divergence it explains, for the same reason
            // EXPECTED_SHORTFALL rides the summary line.
            var detail = control.map { "\($0.headline) " } ?? ""
            detail += "\(candidate.label) diverged from \(baseline.label) at the first "
                + "flip: \(mismatch). NOT scored as a regression: free-running greedy "
                + "decode is a PASS-ONLY signal here, because the incumbent fails it too "
                + "(contiguous-vs-contiguous diverges on this model under the "
                + "operator-reachable DARKBLOOM_CBV2_ATTN_QUERY_BLOCK knob, 977a5893e), "
                + "and because past the "
                + "first flip the two arms decode different contexts so later positions "
                + "compare unrelated conversations"
            if let first = firstDivergingRow(
                baseline: baseline.rows, candidate: candidate.rows),
                let probe = argmaxResolvable(row: first.row, index: first.index)
            {
                measurements["argmaxMargin"] = String(format: "%.3e", probe.margin)
                measurements["resolvableFloor"] = String(format: "%.3e", probe.floor)
                detail += ". The baseline's argmax at that flip had a top1-top2 gap of "
                    + "\(String(format: "%.2e", probe.margin)) against a "
                    + "\(String(format: "%.2e", probe.floor)) floor from the fp16 KV the "
                    + "pool stores, so the tie was "
                    + (probe.resolvable ? "resolvable" : "NOT resolvable")
                    + " at that precision"
            }
            return .init(
                id: id, title: title, verdict: .unavailable, detail: detail,
                measurements: measurements)
        }

        let total = baseline.rows.reduce(0) { $0 + $1.tokens.count }
        // The SHORTEST row, not only the total. A run whose prompts each emit
        // one token before `stop` clears the zero-evidence guard above and
        // reports agreement over three tokens — true, and far thinner than
        // "3 prompts matched" sounds. Disclosing the shortest row makes that
        // thinness unmissable without inventing a minimum-token threshold,
        // which would refuse genuine passes on short-answer prompts. Measured
        // on gemma-4-e2b-it-4bit, where raw un-templated parity prompts do
        // exactly this.
        let shortest = baseline.rows.map(\.tokens.count).min() ?? 0
        return .init(
            id: id, title: title, verdict: .pass,
            detail: "\(baseline.rows.count) prompts, \(total) generated token ids identical "
                + "between \(baseline.label) and \(candidate.label), finish reasons equal "
                + "(shortest row \(shortest) token\(shortest == 1 ? "" : "s"))",
            measurements: measurements)
    }

    // MARK: MTP

    /// MTP parity, scored as PER-ARM losslessness rather than a cross-arm
    /// token diff.
    ///
    /// The cross-arm form cannot carry this criterion, and the reason is
    /// structural rather than incidental. MTP verification emits the TARGET's
    /// own argmaxes, so comparing the two arms' MTP streams to each other
    /// re-measures whatever free-running drift the base decode already has.
    /// That drift is unscoreable — the incumbent reproduces it with no backend
    /// involved (see `tokenExactness`) — and on gemma-4 it is present on 2 of
    /// the 3 parity prompts. A criterion that declines to score inherited
    /// divergence therefore could NEVER reach a FAIL on the one model this
    /// migration is about, which is a gate in name only.
    ///
    /// So each arm is compared against ITSELF: its MTP rows against its own
    /// plain greedy rows. Two properties make that the right bar:
    ///
    ///  1. It is a definitional guarantee, not a tuning target. Greedy
    ///     verified speculation accepts a draft token only where it equals
    ///     the target's own argmax, so a correct MTP implementation
    ///     reproduces plain greedy decode of the same target exactly.
    ///     Deviation is a defect, never taste.
    ///  2. Both sides of the comparison share one backend, its kernels and
    ///     its storage order, so it inherits NOTHING from the cross-backend
    ///     question. Base-decode drift cancels instead of propagating.
    ///
    /// The verdict then keys on whether the reference arm establishes the bar
    /// is reachable at all, which is the same rule `tokenExactness` applies:
    /// baseline lossy -> UNAVAILABLE (a bar the incumbent fails cannot judge
    /// the challenger); baseline lossless and candidate lossy -> FAIL, and it
    /// is attributable; both lossless -> PASS.
    ///
    /// Corollary worth stating, because it replaces a guess with a proof:
    /// once MTP == plain on both arms, a cross-backend MTP difference is
    /// EXACTLY the base-decode difference `token_exactness` reports. The old
    /// code inferred that attribution from "the base also diverges"; here it
    /// follows by construction.
    ///
    /// Row alignment is sound because `BackendParityHarness` generates the
    /// plain and MTP row sets from the same `parityPrompts`, in the same
    /// order, with the same `maxTokens` and EOS set; `rowMismatch` joins on
    /// the prompt name and refuses a count or order mismatch outright.
    ///
    /// KNOWN LIMIT — do not over-read a PASS. Greedy argmax is a COARSE,
    /// non-monotone detector of numeric divergence: matching tokens do not
    /// imply matching numerics. The engine's batch-composition invariance
    /// work measured the gap directly — at unit query gain the attention
    /// output was already wrong in up to 722 of 4096 elements while the
    /// decoded tokens stayed identical for 1024 steps; raising the post-norm
    /// query gain to 8 (an ordinary attention-logit range) saturated the
    /// output to 4096/4096 differing and flipped a token at step 11. So the
    /// blindness is worst on FLAT attention and shrinks as the distribution
    /// peaks. This criterion is scored on real weights and real prompts,
    /// which is the peaked regime, so it is a genuine detector there — but a
    /// PASS means "token-identical", never "numerically identical", and a
    /// synthetic or tiny fixture would weaken it further.
    ///
    /// The obvious hardening — carry a numeric witness alongside the tokens —
    /// is NOT currently available on this path, and the reason is measured
    /// rather than theoretical. `Row.margins` is the witness the base decode
    /// uses, but the harness deliberately requests no `topLogprobs` on the
    /// MTP arm: asking a row for top-k logprobs pulls it off the verification
    /// path back onto the sampler, and the drafter stops engaging. It took
    /// that arm from rounds=5/drafted=5 to rounds=0/drafted=0 on BOTH
    /// backends while `driverConstructed` stayed true — i.e. instrumenting
    /// for numerics manufactured exactly the silent no-op this criterion
    /// exists to catch (`BackendParityHarness.probeMTP`). A numeric witness
    /// here therefore needs a channel that does not run through the sampler,
    /// not merely a flag flip.
    static func mtpTokenExactness(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation
    ) -> BackendParityReport.Criterion {
        let title = "MTP: drafts PRODUCED on both backends and token-exact against "
            + "each backend's OWN plain decode"
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

        // The engine refused to build an MTP driver on BOTH arms for the SAME
        // reason. That is a property of the model/drafter pair or the process
        // config, identical on either backend, so it tells us nothing about
        // paged-vs-contiguous parity and must not be booked as a paged
        // regression. One arm refusing while the other builds IS a backend
        // finding and falls through to the FAIL below.
        if !base.driverConstructed, !cand.driverConstructed,
            base.inactiveReason == cand.inactiveReason
        {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "no MTP driver was constructed on either backend"
                    + (base.inactiveReason.map { " (\($0))" } ?? "")
                    + " — the drafter never engaged on either side, so there is no "
                    + "cross-backend MTP behaviour to compare",
                measurements: measurements)
        }

        // Both arms' MTP streams are EMPTY, which is NOT the same as an inert
        // drafter and must not be scored as one. A failed submission still
        // returns a `Row` — empty token list, `submit_error:` finish reason —
        // so `producedDrafts` below would read "no drafts produced" off a run
        // in which the engine never served the request at all, and book an
        // engine-side refusal as an MTP defect.
        if let baseEmpty = zeroEvidenceReason(base.rows),
            let candEmpty = zeroEvidenceReason(cand.rows)
        {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "the MTP arm generated NOTHING on either backend "
                    + "(\(baseline.label): \(baseEmpty); \(candidate.label): \(candEmpty))"
                    + " — no MTP output was served on either side, so this measures a "
                    + "submission failure rather than MTP behaviour: there is no stream "
                    + "to score for losslessness, and no evidence either way about the "
                    + "drafter. The finish reasons above name the cause",
                measurements: measurements)
        }

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

        // Rows can exist and carry nothing, and `rowMismatch` reads two such
        // streams as token-exact — so without this the self-comparison below
        // would certify MTP losslessness over zero MTP tokens.
        var emptyMTP: [String] = []
        if let reason = zeroEvidenceReason(base.rows) {
            emptyMTP.append("\(baseline.label): \(reason)")
        }
        if let reason = zeroEvidenceReason(cand.rows) {
            emptyMTP.append("\(candidate.label): \(reason)")
        }
        if !emptyMTP.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "drafts were produced but the MTP arm emitted no tokens to score ("
                    + emptyMTP.joined(separator: "; ") + ") — with no MTP output there is "
                    + "nothing to compare against the plain decode",
                measurements: measurements)
        }

        // The own-target comparison needs a target. With no plain rows — or
        // with plain rows that generated nothing — there is nothing to measure
        // losslessness against, and silently comparing the arms to each other
        // instead is the failure mode this criterion was rewritten to remove.
        var emptyPlain: [String] = []
        if let reason = zeroEvidenceReason(baseline.rows) {
            emptyPlain.append("\(baseline.label): \(reason)")
        }
        if let reason = zeroEvidenceReason(candidate.rows) {
            emptyPlain.append("\(candidate.label): \(reason)")
        }
        if !emptyPlain.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "MTP rows were captured but the plain greedy decode they must be "
                    + "compared against generated nothing ("
                    + emptyPlain.joined(separator: "; ") + ") — with no own-target decode "
                    + "there is nothing to measure MTP losslessness against",
                measurements: measurements)
        }

        let baseSelf = rowMismatch(baseline: baseline.rows, candidate: base.rows)
        let candSelf = rowMismatch(baseline: candidate.rows, candidate: cand.rows)

        var evidence = measurements
        evidence["\(baseline.label) MTP vs own decode"] = baseSelf ?? "token-exact"
        evidence["\(candidate.label) MTP vs own decode"] = candSelf ?? "token-exact"
        let crossBackend = rowMismatch(baseline: base.rows, candidate: cand.rows)
        if let crossBackend { evidence["crossBackendMTP"] = crossBackend }

        // The incumbent fails the bar, so the bar cannot judge the challenger.
        // Reported with the candidate's own result, because "we could not
        // score this" must not hide the fact that the candidate may have
        // cleared it outright.
        if let baseSelf {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "the INCUMBENT failed this bar, so it cannot judge the "
                    + "challenger. MTP is NOT token-exact against its own plain greedy "
                    + "decode on the reference arm \(baseline.label): \(baseSelf). MTP "
                    + "losslessness is therefore not scoreable on this model/drafter "
                    + "pair. This is NOT a statement that \(candidate.label) is "
                    + "untestable or unproven — measured on its own, \(candidate.label) "
                    + "was "
                    + (candSelf.map { "not token-exact either: \($0)" }
                        ?? "token-exact against its own plain decode"),
                measurements: evidence)
        }

        // The reference arm PROVED the bar is reachable on this model and this
        // drafter, and the candidate missed it. This comparison crosses no
        // backend boundary, so it cannot be explained away as inherited
        // base-decode drift — it is MTP on the candidate backend.
        if let candSelf {
            return .init(
                id: id, title: title, verdict: .fail,
                detail: "MTP output diverged from \(candidate.label)'s OWN plain greedy "
                    + "decode, while MTP on \(baseline.label) reproduces its own decode "
                    + "exactly. Verified greedy speculation is lossless by construction, "
                    + "so this is introduced by MTP on \(candidate.label): it crosses no "
                    + "backend boundary and inherits no base-decode drift: \(candSelf)",
                measurements: evidence)
        }

        var detail = "both backends drafted (\(base.draftedTokens) and "
            + "\(cand.draftedTokens) draft tokens over \(base.rounds) and \(cand.rounds) "
            + "rounds) and MTP reproduced each backend's OWN plain greedy decode token "
            + "for token across \(base.rows.count) prompts, so MTP introduces no "
            + "divergence on either backend"
        if let crossBackend {
            detail += ". The two backends' MTP streams DO differ from each other, but "
                + "with MTP token-exact against its own target on both arms that "
                + "difference is EXACTLY the base-decode divergence token_exactness "
                + "reports — inherited, not introduced by MTP: \(crossBackend)"
        }
        return .init(
            id: id, title: title, verdict: .pass, detail: detail,
            measurements: evidence)
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

    /// Two questions, and the second one is why this criterion exists at all.
    ///
    /// 1. Did the candidate SKIP at least as much prefill as the baseline?
    /// 2. Did skipping it change the answer?
    ///
    /// (2) was absent until an adoption defect walked straight through a PASS:
    /// paged adopted diverged from paged COLD at token 20 of 32 while this
    /// criterion reported exact parity, because "26,880 = 26,880" is a true
    /// statement about token COUNTS and silent about correctness. Savings are
    /// meaningful only conditional on exactness, so a proven-inexact adoption
    /// is a FAIL here regardless of how much work it appeared to save.
    ///
    /// WHAT A PASS DOES NOT PROVE. The exactness half is WITHIN-ARM: each
    /// backend's adopting request is compared against its OWN cold request,
    /// never against the other backend. That is deliberate — it crosses no
    /// backend boundary and so inherits none of the base-decode divergence
    /// that makes `token_exactness` unsatisfiable on gemma-4 — but it means a
    /// PASS says NOTHING about the two backends agreeing with each other.
    /// `token_exactness` is the criterion for that question; this one cannot
    /// answer it and must not be read as if it had.
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
        // nothing to match. Three DIFFERENT failures reach this point and they
        // used to render identically, which made the criterion unfalsifiable
        // in the same shape the MTP criterion had: a probe that never enabled
        // the cache and a backend that genuinely refused to donate both read
        // "the probe never ran". `donationDiagnosis` separates them.
        var undonated: [(label: String, reuse: BackendParityObservation.PrefixReuse)] = []
        if base.donatedEntries == 0 { undonated.append((baseline.label, base)) }
        if cand.donatedEntries == 0 { undonated.append((candidate.label, cand)) }
        if !undonated.isEmpty {
            return .init(
                id: id, title: title, verdict: .unavailable,
                detail: "no prefix was donated to the cache on "
                    + undonated.map { "\($0.label) (\(donationDiagnosis($0.reuse)))" }
                        .joined(separator: " and ")
                    + ", so the second request had nothing to match",
                measurements: measurements)
        }

        // Exactness BEFORE arithmetic, and unconditional on it: a backend that
        // saves prefill by returning a different answer has not saved
        // anything. Judged per arm against that arm's OWN cold request.
        //
        // But WHICH arms differ is the whole signal, because a cold prefill
        // and an adopted replay do not take the same floating-point path even
        // when adoption is correct — different chunk boundaries, different
        // accumulation order. On a precision-sensitive model that drift alone
        // can move an argmax (gemma-4 amplifies it ~1,300x over gpt-oss, which
        // is why `token_exactness` reads UNAVAILABLE there). So a raw "the
        // tokens differ" must NEVER be reported as a paged defect on its own:
        // symmetric inexactness is a property of the MODEL, and only an
        // asymmetry — one backend exact, the other not, same prompt, same
        // process — isolates the backend. Both still FAIL, because a cache the
        // caller cannot see must not change the answer either way, but they
        // are never allowed to read alike.
        let inexact = [(baseline.label, base), (candidate.label, cand)]
            .filter { $0.1.adoptionTokenExact == false }
        if !inexact.isEmpty {
            let exactArms = [(baseline.label, base), (candidate.label, cand)]
                .filter { $0.1.adoptionTokenExact == true }
            var detail = "adoption CHANGED THE ANSWER on "
                + inexact.map(\.0).joined(separator: " and ")
                + ": the adopting request returned different tokens than the cold "
                + "request for the SAME prompt at temperature 0, so the reported "
                + "savings are not savings — prefill was skipped that was needed. "
                + "Token counts are only meaningful conditional on exactness, which "
                + "is why this outranks the comparison below"
            if let exact = exactArms.first {
                detail += ". ASYMMETRIC, which isolates the backend: \(exact.0) adopted "
                    + "the same prefix on the same prompt in the same process and stayed "
                    + "exact, so precision sensitivity cannot explain this one"
            } else {
                detail += ". SYMMETRIC — every measured arm is inexact, so this is a "
                    + "property of the MODEL (a cold prefill and an adopted replay "
                    + "accumulate differently, and this checkpoint's argmax is sensitive "
                    + "enough to show it), NOT evidence against either backend. Do not "
                    + "cite it as one; see the precision caveat on token_exactness"
            }
            return .init(
                id: id, title: title, verdict: .fail, detail: detail,
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

        // The structural allowance, derived from the two measured
        // capabilities rather than hardcoded. It USED to be one `maxWindow`:
        // paged's frozen-replay bound was contiguous's plus that term, so the
        // difference of the arms' bounds was the allowance.
        //
        // As of the frozen-chunk gather the two bounds are the SAME
        // expression, so on today's engine this evaluates to ZERO and a paged
        // prefill shortfall is UNEXCUSED — it reports FAIL, not
        // EXPECTED_SHORTFALL. That is the intended outcome and the reason the
        // allowance is derived rather than written down: it retired itself
        // when the cause was fixed, with no edit here.
        //
        // It stays because a future backend may legitimately carry a bound of
        // its own, and because a non-zero value must never again be assumed
        // to mean `maxWindow` specifically.
        let structuralAllowance = max(0, cand.replayBoundTokens - base.replayBoundTokens)
        let shortfall = base.secondPrefillTokensSaved - cand.secondPrefillTokensSaved

        if shortfall > 0 {
            // Percentage, not just tokens: the same one-window cost is 0.5%
            // of contiguous's saving on a 128-token-window model and 36% on a
            // 1024-token-window one. The absolute count hides exactly the
            // thing a release decision needs to weigh.
            let percent = base.secondPrefillTokensSaved > 0
                ? Double(shortfall) / Double(base.secondPrefillTokensSaved) * 100
                : 0
            let magnitude = String(format: "%.1f", percent)
            var detail = "\(candidate.label) saved \(cand.secondPrefillTokensSaved) prefill "
                + "tokens against \(base.secondPrefillTokensSaved) on \(baseline.label) — "
                + "short by \(shortfall) (\(magnitude)% of the baseline's saving)"

            // The allowance is the price of DOING frozen replay on paged. A
            // backend whose capability derived UNSUPPORTED is not paying that
            // price, it is not reusing at all — that is a defect, and letting
            // it hide behind the structural band would be the exact laundering
            // this verdict exists to prevent.
            if shortfall <= structuralAllowance, structuralAllowance > 0,
                cand.capabilitySupported
            {
                detail += ". That is within the documented structural cost: paged pays one "
                    + "maxWindow (\(structuralAllowance) tokens) of extra frozen replay by "
                    + "construction, so this is NOT a regression — and it is NOT parity "
                    + "either. The cost scales as maxWindow/matched, so it is negligible on "
                    + "short-window models and severe on long-window ones. Note the "
                    + "allowance is one maxWindow, NOT one prefill chunk — they differ on "
                    + "every model measured so far"
                return .init(
                    id: id, title: title, verdict: .expectedShortfall, detail: detail,
                    measurements: measurements)
            }

            if !cand.capabilitySupported, let reason = cand.capabilityUnsupportedReason {
                detail += " — the backend's prefix-reuse capability is unsupported: \(reason)"
            } else if structuralAllowance > 0 {
                detail += ", which EXCEEDS the \(structuralAllowance)-token structural "
                    + "allowance (one maxWindow) — the excess is a real regression"
            }
            return .init(
                id: id, title: title, verdict: .fail, detail: detail,
                measurements: measurements)
        }

        // Disclose how much of the prompt adoption actually SKIPPED, because
        // that is the exactness oracle's sample size and it is often small.
        // `frozenFullReplay` replays `min(matched, replayBound)` of the match,
        // so on gemma-4 at 28,672 the adopting request re-does 89% of the
        // prompt and only ~10% is genuinely adopted. "Adoption was exact"
        // there is a much smaller claim than it sounds, and a reader deciding
        // whether to trust paged adoption needs the denominator.
        //
        // Disclosed, never enforced: a reuse-fraction threshold would turn a
        // thin measurement into a refusal to measure, which is the failure
        // this criterion has already been fixed for twice.
        var detail = "\(candidate.label) saved \(cand.secondPrefillTokensSaved) prefill tokens, "
            + ">= \(base.secondPrefillTokensSaved) on \(baseline.label)"
        if structuralAllowance > 0 {
            detail += " — and it beat the \(structuralAllowance)-token structural allowance, "
                + "which is surprising and worth checking"
        }
        let exercised = [base, cand].compactMap { arm -> Double? in
            guard arm.promptTokens > 0, arm.adoptionTokenExact != nil else { return nil }
            return Double(arm.secondPrefillTokensSaved) / Double(arm.promptTokens) * 100
        }
        if let weakest = exercised.min() {
            detail += ". Adoption was token-exact against each arm's OWN cold request, but "
                + "note the sample: the thinner arm actually skipped only "
                + String(format: "%.1f", weakest) + "% of its prompt "
                + "(the rest was frozen replay, which re-does the cold arithmetic and so "
                + "cannot diverge). Read this as 'the adoption performed here was exact', "
                + "NOT as 'adoption is exact'"
        } else {
            detail += ". Adoption exactness was NOT MEASURED on either arm, so this verdict "
                + "is about token COUNTS only and says nothing about whether reuse changes "
                + "the answer"
        }
        return .init(
            id: id, title: title, verdict: .pass, detail: detail,
            measurements: measurements)
    }

    // MARK: - Comparators

    /// Why a token stream is not evidence: it has no rows at all, or it has
    /// rows and not one of them generated a token. Nil when at least one
    /// token was generated.
    ///
    /// `rowMismatch` is blind to this BY CONSTRUCTION, and that blindness is
    /// how a gate reports parity over nothing. When a submission fails,
    /// `BackendParityHarness.generate` still returns a `Row` — empty token
    /// list, `submit_error:` finish reason — so two arms that failed the same
    /// way produce equal-length arrays of empty streams which compare EQUAL,
    /// and every token criterion in this file then takes its PASS branch over
    /// zero generated tokens. Same shape as the two other gates-that-cannot-
    /// fail fixed on this PR: absence rendered as agreement.
    ///
    /// The rendered reason names the finish reasons the rows carried, because
    /// that is where the actual cause (the submission failure) is recorded.
    static func zeroEvidenceReason(_ rows: [BackendParityObservation.Row]) -> String? {
        guard !rows.isEmpty else { return "no rows at all" }
        guard rows.allSatisfy({ $0.tokens.isEmpty }) else { return nil }
        let reasons = Set(rows.map(\.finishReason).filter { !$0.isEmpty }).sorted()
        return "\(rows.count) row(s), 0 generated tokens, "
            + (reasons.isEmpty
                ? "no finish reason recorded"
                : "finish=\(reasons.joined(separator: "/"))")
    }

    /// The blocking reason when a PAIR of token streams cannot be compared at
    /// all, or nil when both arms generated something.
    ///
    /// The two cases are deliberately worded apart. "Neither arm generated
    /// anything" is an absence of evidence and must never read like
    /// agreement; "one arm generated nothing" is an asymmetry whose empty
    /// side still carries no information about the other.
    static func zeroEvidenceBlocker(
        baselineLabel: String,
        baselineRows: [BackendParityObservation.Row],
        candidateLabel: String,
        candidateRows: [BackendParityObservation.Row]
    ) -> String? {
        switch (zeroEvidenceReason(baselineRows), zeroEvidenceReason(candidateRows)) {
        case (nil, nil):
            return nil
        case (.some(let baseReason), .some(let candReason)):
            return "NOTHING WAS COMPARED — this is NOT agreement between the backends. "
                + "Neither arm generated a token (\(baselineLabel): \(baseReason); "
                + "\(candidateLabel): \(candReason)), and two empty token streams are "
                + "trivially identical, so scoring them would report an absence of "
                + "evidence as parity. The finish reasons above name the cause"
        case (.some(let baseReason), nil):
            return "\(baselineLabel) generated no tokens (\(baseReason)) while "
                + "\(candidateLabel) generated \(tokenSummary(candidateRows)) — an empty "
                + "stream carries no information about the other arm, so there is nothing "
                + "to compare"
        case (nil, .some(let candReason)):
            return "\(candidateLabel) generated no tokens (\(candReason)) while "
                + "\(baselineLabel) generated \(tokenSummary(baselineRows)) — an empty "
                + "stream carries no information about the other arm, so there is nothing "
                + "to compare"
        }
    }

    /// Every per-row divergence between two token-id streams, or nil when
    /// every row matches exactly (ids AND finish reason).
    ///
    /// All rows, not just the first: "1 of 3 rows drifted at token 1" and
    /// "3 of 3 rows drifted at token 0" are very different bugs, and a
    /// first-match-wins message cannot tell them apart.
    static func rowMismatch(
        baseline: [BackendParityObservation.Row],
        candidate: [BackendParityObservation.Row]
    ) -> String? {
        guard baseline.count == candidate.count else {
            return "row count differs: \(baseline.count) vs \(candidate.count)"
        }
        var diverged: [String] = []
        for (base, cand) in zip(baseline, candidate) {
            guard base.prompt == cand.prompt else {
                return "prompt order differs: '\(base.prompt)' vs '\(cand.prompt)'"
            }
            if let index = firstDivergence(base.tokens, cand.tokens) {
                let lhs = base.tokens.count > index ? "\(base.tokens[index])" : "<end>"
                let rhs = cand.tokens.count > index ? "\(cand.tokens[index])" : "<end>"
                diverged.append(
                    "prompt '\(base.prompt)' token \(index): \(lhs) vs \(rhs) "
                        + "(lengths \(base.tokens.count) vs \(cand.tokens.count))")
            } else if base.finishReason != cand.finishReason {
                diverged.append(
                    "prompt '\(base.prompt)' finish reason: "
                        + "\(base.finishReason) vs \(cand.finishReason)")
            }
        }
        guard !diverged.isEmpty else { return nil }
        return "\(diverged.count) of \(baseline.count) rows diverged — "
            + diverged.joined(separator: "; ")
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
        return "\(rows.count) rows, \(total) tokens, finish=\(reasons.isEmpty ? "none" : reasons)"
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

    /// Why an arm donated nothing. "Cache was off" and "cache was on and the
    /// donor did not publish" are DIFFERENT failures with different owners,
    /// and rendering them identically is what let a non-measurement read as a
    /// harness hiccup for a whole release cycle.
    ///
    /// The discriminator is that `disabled` is the ONLY outcome
    /// `EngineV2.makePrefixLookup` can return with a nil cache — it is the
    /// first guard in that function, and every other outcome is produced past
    /// it. `PrefixCacheV2`'s hit/miss counters say the same thing from the
    /// other side: they only advance inside `lookup`, which that guard
    /// protects. So either signal is positive proof a cache was LIVE,
    /// whatever the terminal usage went on to claim.
    static func donationDiagnosis(_ reuse: BackendParityObservation.PrefixReuse) -> String {
        let lookups = reuse.cacheHits + reuse.cacheMisses
        let outcomes = [reuse.firstOutcome, reuse.secondOutcome].filter { !$0.isEmpty }
        let cacheProvenLive = lookups > 0 || outcomes.contains { $0 != "disabled" }
        let finish = reuse.firstFinishReason
        let finishNote = finish.isEmpty ? "finish not recorded" : "finish=\(finish)"

        if !reuse.capabilitySupported {
            return "prefix reuse is UNSUPPORTED for this backend and layout"
                + (reuse.capabilityUnsupportedReason.map { " (\($0))" } ?? "")
                + " — EngineV2.init drops the cache, so nothing could ever donate"
        }
        if !cacheProvenLive {
            return "CACHE OFF: no lookup ever reached the cache and every submission "
                + "reported 'disabled' — prefix caching was not active for this probe, so "
                + "the run measured the harness, not the backend"
        }
        if reuse.firstOutcome == "disabled" {
            return "MIS-REPORTED: the donor reported 'disabled', but this arm also shows "
                + "\(lookups) cache lookup(s) and a second outcome of "
                + "'\(reuse.secondOutcome)' — both unreachable without a LIVE cache. The "
                + "donor's terminal (\(finishNote)) therefore bypassed its per-request "
                + "prefix record and fell back to CBv2Usage's default outcome. That is an "
                + "engine TELEMETRY defect in the forced-terminal paths, which publish the "
                + "seeded usage snapshot; it is NOT a cache-configuration problem and NOT "
                + "evidence the backend cannot reuse"
        }
        if !finish.isEmpty, finish != "stop", finish != "length" {
            return "the donor did not finish cleanly (\(finishNote)); "
                + "EngineLoopV2.donationIntent refuses to donate from a cancelled, error or "
                + "terminal finish because partial KV is not a confirmed prefix"
        }
        return "the donor reported '\(reuse.firstOutcome)' (\(finishNote)) over \(lookups) "
            + "lookup(s) against a live cache, but no entry was indexed before the donation "
            + "timeout — a real donation-path failure, not a configuration gap"
    }

    static func prefixSummary(_ reuse: BackendParityObservation.PrefixReuse) -> String {
        var summary = "capability=\(reuse.capabilitySupported ? "supported" : "unsupported")"
        if let strategy = reuse.capabilityStrategy { summary += "(\(strategy))" }
        if let reason = reuse.capabilityUnsupportedReason { summary += "(\(reason))" }
        summary += ", replayBound=\(reuse.replayBoundTokens)"
        summary += ", prompt=\(reuse.promptTokens)"
        summary += ", donated=\(reuse.donatedEntries)"
        summary += ", outcomes=\(reuse.firstOutcome)->\(reuse.secondOutcome)"
        // Omitted rather than printed empty while the harness half of this
        // change is still uncommitted, so the line never reads `finish=/`.
        if !reuse.firstFinishReason.isEmpty || !reuse.secondFinishReason.isEmpty {
            summary += ", finish=\(reuse.firstFinishReason)/\(reuse.secondFinishReason)"
        }
        summary += ", matched=\(reuse.secondMatchedTokens)"
        summary += ", saved=\(reuse.secondPrefillTokensSaved)"
        // The oracle's verdict and its sample size travel together: "exact"
        // over 9.8% of a prompt is a far smaller claim than over 56%, and
        // splitting them is how a thin measurement gets quoted as a strong one.
        switch reuse.adoptionTokenExact {
        case .some(true): summary += ", adoptionExact=true"
        case .some(false): summary += ", adoptionExact=FALSE"
        case nil: summary += ", adoptionExact=not_measured"
        }
        if reuse.promptTokens > 0, reuse.adoptionTokenExact != nil {
            let pct = Double(reuse.secondPrefillTokensSaved) / Double(reuse.promptTokens) * 100
            summary += ", reused=" + String(format: "%.1f", pct) + "%"
        }
        summary += ", cache(hits=\(reuse.cacheHits),misses=\(reuse.cacheMisses),"
        summary += "tokensSaved=\(reuse.cacheTokensSaved))"
        return summary
    }
}
