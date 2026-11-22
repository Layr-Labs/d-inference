// Copyright © 2026 Eigen Labs.

extension GenerationLoopGuardPolicy {
    /// What the loop guard does by default for one served model type.
    enum Decision: Sendable, Equatable {
        /// In the default list (`defaultModelTypes`), with this way out of a
        /// repeating thought.
        case guarded(exit: Exit)
        /// Not in the default list, for the reason on record.
        case unguarded(reason: String)

        /// A guarded type's default in `GenerationLoopExitThinkingPolicy`.
        enum Exit: Sendable, Equatable {
            typealias Markers = GenerationLoopExitThinkingPolicy.Markers

            /// Ends a repeating thought on every build.
            case on(Markers)
            /// Ends it on the builds a GPU A/B proved, by catalog id. Another
            /// build keeps `length` unless a list set on the Mac names it
            /// (`GenerationLoopExitThinkingPolicy.keepsLength`).
            case provenBuilds(Markers, ids: [String])
            /// Has the markers and stays off until a list set on the Mac
            /// names the type.
            case optIn(Markers)
            /// No markers: its loops keep ending as `length`, for the reason
            /// on record.
            case keepsLength(reason: String)

            var markers: Markers? {
                switch self {
                case .on(let markers), .provenBuilds(let markers, _), .optIn(let markers): markers
                case .keepsLength: nil
                }
            }

            /// Whether the default `DARKBLOOM_LOOP_EXIT_THINKING` list holds the type.
            var isOnByDefault: Bool {
                switch self {
                case .on, .provenBuilds: true
                case .optIn, .keepsLength: false
                }
            }

            var provenBuildIDs: [String] {
                if case .provenBuilds(_, let ids) = self { ids } else { [] }
            }
        }

        /// The exit of a guarded type; nil for an unguarded one.
        var exit: Exit? {
            switch self {
            case .guarded(let exit): exit
            case .unguarded: nil
            }
        }
    }

    /// The default for every served model type. The default lists of both
    /// policies are read from here (`defaultModelTypes`, and
    /// `GenerationLoopExitThinkingPolicy`'s `markersByModelType`,
    /// `defaultModelTypes` and `provenBuilds`).
    ///
    /// No `default:`: a new `ServedModelType` case fails to build until it is
    /// decided here, so a type is never off because a list left it out.
    static func decision(_ type: ServedModelType) -> Decision {
        typealias Thought = GenerationLoopExitThinkingPolicy
        switch type {
        case .gemma4, .gemma4Text:
            return .guarded(exit: .on(Thought.gemmaChannel))
        case .gptOSS:
            return .guarded(exit: .on(Thought.harmonyAnalysis))
        case .qwen35:
            return .guarded(exit: .provenBuilds(Thought.qwenThink, ids: ["Qwen3.5-9B"]))
        case .qwen35MoE:
            return .guarded(exit: .provenBuilds(
                Thought.qwenThink, ids: ["qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"]))
        case .nemotronHOmni:
            return .guarded(exit: .optIn(Thought.superThink))
        case .qwen4Exp:
            return .guarded(exit: .keepsLength(
                reason: "its thought loops are rare in production, and no A/B has qualified an exit"))
        case .qwen4ExpText, .nemotronH, .glm5Next, .mimoV2:
            return .guarded(exit: .keepsLength(reason: "no A/B has qualified an exit from its thought"))
        case .diffusionGemma, .flint, .prismHadamardQwen35, .qwen3VLMoE:
            return .unguarded(
                reason: "not among the families whose answers were seen repeating verbatim to their cap")
        }
    }
}
