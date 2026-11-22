// Copyright © 2026 Eigen Labs.

import MLXLMCommon

/// Whether a request's tool calls leave while they are generated or only once
/// they are complete.
///
/// A streamed call leaves as its name, then argument fragments, and is checked
/// when its frame closes. A withheld call is parsed and validated at the end
/// of generation, then released whole. Both owners that expose calls resolve
/// it here, the scheduler (`ToolStreamPreparation`) and Nemotron 3.5 Super's
/// own output (`NemotronSuperLocalOutput`), so a rule decided for one is not
/// ported to the other by hand.
enum ToolCallExposure: Equatable, Sendable {
    /// Calls leave as fragments, read from `Source`.
    case streamed(Source)
    /// Calls are held to the end of generation, for `Reason`.
    case withheld(Reason)

    /// Where a streamed call's fragments are read.
    enum Source: Equatable, Sendable {
        /// The request's parser renders each frame as it arrives
        /// (`ToolCallStreamingOptions`).
        case parserFrames
        /// The router reads GLM's frames from the answer channel
        /// (`GLM5ToolCallStream`): the SDK's GLM parser keeps its whole tool
        /// suffix to the end of generation.
        case glmFrames
    }

    enum Reason: Equatable, Sendable {
        /// A switch the operator turned off.
        case switchedOff(Switch)
        /// The surface relays complete calls only: `streamToolCallDeltas` is
        /// off, or Super's owner collects the response.
        case surfaceRendersNoFragments
        /// `tool_choice: none`.
        case toolChoiceNone
        /// The request offers no tool to call.
        case noToolsOffered
        /// The client itself does not stream (`Prepared.clientStreams`).
        case clientDoesNotStream
        /// The answer is a JSON value its owner withholds until it validates.
        case jsonAnswerWithheld
        /// The request's parser has no incremental argument renderer.
        case parserRendersNoFragments
        /// The request's parser is MiMo's or Nemotron's, which stream for
        /// their own served builds alone, or is not its family's own.
        case parserOfAnotherFamily
        /// The request's forced choice is enforced by another strategy than
        /// the one this family's forced calls stream under.
        case forcedByAnotherStrategy
        /// The family's own reason, on record in `Family`.
        case family(String)
    }

    enum Switch: Equatable, Sendable {
        /// `DARKBLOOM_TTFT_STREAM_TOOL_CALLS`.
        case toolCalls
        /// `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS`, or the family's own
        /// (`ToolStreamPreparation.ForcedCalls`).
        case forcedToolCalls
        /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS`.
        case nativeToolCalls
        /// `DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS`.
        case glmToolCalls
    }

    var streams: Bool {
        switch self {
        case .streamed: true
        case .withheld: false
        }
    }
}

// MARK: - The decision per family

extension ToolCallExposure {
    /// How one model's calls may leave while they are generated.
    enum Family: Equatable, Sendable {
        /// `auto` calls stream to any surface that renders fragments, through
        /// any parser that renders them except MiMo's and Nemotron's.
        /// `forced` decides `required` and named calls.
        case framed(forced: Forced)
        /// A native-channel family: its reasoning is split off before tool
        /// parsing, and its `auto` and forced calls stream to a client that
        /// streams, through `parser`, its own, while
        /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS` is on. Forced calls also
        /// need the forced master switch (`ForcedCalls.native`).
        case nativeChannel(parser: ToolCallFormat)
        /// GLM-5.3-Flash: `auto` and forced calls stream to a client that
        /// streams, read by the router, unless its JSON answer is withheld.
        /// Under another parser it is a `framed` family without forced streams.
        case glm
        /// Nemotron 3.5 Super served by its own owner
        /// (`NemotronSuperLocalOutput`): as a native-channel family, unless
        /// its JSON answer is withheld or it offers no tool.
        case superOwner
        /// Nothing streams, for the reason on record.
        case withheld(reason: String)

        /// A `framed` family's `required` and named calls.
        enum Forced: Equatable, Sendable {
            /// Stream to a client that streams when this strategy is what
            /// enforces the request's choice
            /// (`ToolChoiceEnforcementPolicy.forcedStrategy`), while that
            /// strategy's switch is on (`ForcedCalls`). Each call is still
            /// checked in full when its frame closes, and one that fails
            /// after it started is refused, never finished
            /// (`FailedStreamedCallPolicy` does not apply to forced calls).
            /// Withheld, a long forced answer had no first content before
            /// generation ended and missed the coordinator's first-content
            /// deadline.
            case streams(under: ToolChoiceEnforcementPolicy.Strategy)
            /// Keep validate-then-expose, for the reason on record.
            case withheld(reason: String)
        }

        /// The family of a served model type as config.json declares it, on
        /// the scheduler's path.
        ///
        /// No `default:`: a new `ServedModelType` case fails to build until its
        /// exposure is decided here, so a family is never withheld because a
        /// list left it out.
        static func served(_ type: ServedModelType, modelID: String?) -> Family {
            switch type {
            case .gemma4, .gemma4Text:
                // The sampler's grammar holds a forced call to a declared
                // function and its schema.
                return .framed(forced: .streams(under: .gemmaGrammar))
            case .gptOSS:
                // The sampler admits only a declared function's Harmony
                // header, then one JSON object of its schema.
                return .framed(forced: .streams(under: .harmonyFraming))
            case .qwen35, .qwen35MoE:
                // Prompt-forced, with reasoning split off before the frames
                // (`splitsQwenReasoningBeforeTools`); checked at each close.
                return .framed(forced: .streams(under: .structuredPostValidation))
            case .qwen3VLMoE:
                return .framed(forced: .withheld(
                    reason: "its reasoning is not split off before its tool frames; no forced stream is qualified"))
            case .prismHadamardQwen35:
                let context = ChatTemplateFixContext(modelId: modelID, modelType: type.rawValue)
                return ToolChoiceEnforcementPolicy.nativeStructuredTarget(context)
                    ? .nativeChannel(parser: .qwen35)
                    : .framed(forced: .withheld(reason: "only the admitted Bonsai builds stream forced calls"))
            case .mimoV2:
                return .nativeChannel(parser: .mimoV2)
            case .nemotronH:
                return EngineV2SupportedModels.isNemotron35ListingModelID(modelID)
                    ? .nativeChannel(parser: .nemotron)
                    : .framed(forced: .withheld(reason: "only the listed Lightning builds stream"))
            case .nemotronHOmni:
                return .framed(forced: .withheld(
                    reason: "Super is served by its own owner, which resolves `superOwner`"))
            case .glm5Next:
                return .glm
            case .qwen4Exp, .qwen4ExpText, .diffusionGemma, .flint:
                return .withheld(
                    reason: "a native-channel family no stream is qualified for; it keeps its withheld framing")
            }
        }

        /// A served model type under another spelling: another letter case,
        /// or surrounding whitespace. The supported set admits a type that
        /// way (`ServedModelType.init(normalizing:)`), and a cluster pair's
        /// slot takes its `model_type` as registered, so such a string can
        /// reach the tool path. The rules this decision replaced each read
        /// the type with their own tolerance; what they gave together is kept
        /// here, one decision per type, so that reading the type through one
        /// normalisation changed nothing.
        static func respelled(_ type: ServedModelType, modelID: String?) -> Family {
            switch type {
            case .gptOSS, .gemma4, .gemma4Text, .qwen35, .qwen35MoE, .qwen3VLMoE, .nemotronHOmni, .qwen4Exp,
                .qwen4ExpText, .diffusionGemma:
                // Read under any spelling. (Gemma's forced calls still need
                // the Gemma grammar, which no padded spelling selects.)
                return served(type, modelID: modelID)
            case .prismHadamardQwen35, .nemotronH:
                // A listed build keeps its native framing under any spelling,
                // but its stream was read from the exact type: nothing
                // streams. An unlisted build is a framed family either way.
                let declared = served(type, modelID: modelID)
                if case .nativeChannel = declared {
                    return .withheld(
                        reason: "a listed native-channel build whose type is not spelled as config.json declares it")
                }
                return declared
            case .mimoV2, .glm5Next, .flint:
                // Recognised only as declared. Under another spelling it has
                // neither its native framing nor a forced strategy.
                return .framed(forced: .withheld(
                    reason: "its type is not spelled as config.json declares it; no forced stream is qualified"))
            }
        }

        /// A `model_type` that names no served type under any spelling, or no
        /// type at all. Its `auto` calls stream as a framed family's. Two
        /// rules that read such a request are kept: GLM's text and MTP
        /// component types take GLM's stream (`GLM5NextPromptPolicy.applies`),
        /// and a forced call streams under the Gemma grammar alone, which
        /// `Gemma4TemplateFix.applies` selects for `gemma4_vision` and, with
        /// no type, for a model id that holds `gemma-4`.
        static func unserved(_ context: ChatTemplateFixContext) -> Family {
            GLM5NextPromptPolicy.applies(modelType: context.modelType)
                ? .glm : .framed(forced: .streams(under: .gemmaGrammar))
        }

        /// The family of a request's model on the scheduler's path. The type
        /// is read as the supported set reads it, so the two cannot disagree
        /// about which strings name a served type.
        static func of(_ context: ChatTemplateFixContext) -> Family {
            guard let type = ServedModelType(normalizing: context.modelType) else { return unserved(context) }
            return context.modelType == type.rawValue
                ? served(type, modelID: context.modelId) : respelled(type, modelID: context.modelId)
        }
    }
}

// MARK: - The decision per request

extension ToolCallExposure {
    /// What the decision reads of one request.
    struct Request: Equatable, Sendable {
        /// The prepared tool choice.
        var mode: ToolConstraintMode
        /// The client itself streams (`Prepared.clientStreams`).
        var clientStreams: Bool
        /// The surface relays call fragments (`streamToolCallDeltas`, and for
        /// Super's owner a response it streams).
        var rendersFragments: Bool
        /// The choice offers at least one declared tool.
        var offersTools: Bool
        /// The answer is a JSON value this owner withholds until it
        /// validates: GLM's (`Prepared.glmResponseFormat`) and Super's.
        var withholdsJSONAnswer: Bool
        /// What enforces the request's forced choice on the scheduler's path
        /// (`ToolChoiceEnforcementPolicy.forcedStrategy`); `.none` for
        /// `auto`, and for Super's owner, whose plan prompt-forces its calls.
        /// Read for a `framed` family's forced calls alone.
        var forcedStrategy: ToolChoiceEnforcementPolicy.Strategy
    }

    /// The streaming switches, each read once per process
    /// (`ToolStreamPreparation`). No member has a default: an owner states
    /// every switch it resolves under, so none is left on by omission.
    struct Switches: Equatable, Sendable {
        /// `DARKBLOOM_TTFT_STREAM_TOOL_CALLS`.
        var toolCalls: Bool
        /// `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS` and each family's own.
        var forced: ToolStreamPreparation.ForcedCalls
        /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS`.
        var native: Bool
        /// `DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS`.
        var glm: Bool
    }

    /// The exposure of one request's calls. `parser` is the format its tool
    /// handler parses (`ServerToolParser.resolve`). `switches` has no default:
    /// each owner states the ones it serves under.
    static func resolve(
        family: Family, parser: ToolCallFormat, request: Request, switches: Switches
    ) -> ToolCallExposure {
        guard switches.toolCalls else { return .withheld(.switchedOff(.toolCalls)) }
        guard request.rendersFragments else { return .withheld(.surfaceRendersNoFragments) }
        let forced: Bool
        switch request.mode {
        case .none: return .withheld(.toolChoiceNone)
        case .auto: forced = false
        case .required, .named: forced = true
        }
        switch family {
        case .withheld(let reason):
            return .withheld(.family(reason))
        case .framed(let forcedCalls):
            return framed(parser: parser, forced: forced ? forcedCalls : nil, request: request, switches: switches)
        case .nativeChannel(let own):
            guard parser == own else { return .withheld(.parserOfAnotherFamily) }
            return nativeChannel(parser: parser, forced: forced, request: request, switches: switches)
        case .superOwner:
            guard request.offersTools else { return .withheld(.noToolsOffered) }
            guard !request.withholdsJSONAnswer else { return .withheld(.jsonAnswerWithheld) }
            return nativeChannel(parser: parser, forced: forced, request: request, switches: switches)
        case .glm:
            guard parser == .glm5 else {
                let forcedCalls = Family.Forced.withheld(reason: "GLM's forced calls stream through its own parser")
                return framed(parser: parser, forced: forced ? forcedCalls : nil, request: request, switches: switches)
            }
            guard switches.glm else { return .withheld(.switchedOff(.glmToolCalls)) }
            guard !forced || switches.forced[.glm] else { return .withheld(.switchedOff(.forcedToolCalls)) }
            guard request.clientStreams else { return .withheld(.clientDoesNotStream) }
            guard !request.withholdsJSONAnswer else { return .withheld(.jsonAnswerWithheld) }
            guard request.offersTools else { return .withheld(.noToolsOffered) }
            return .streamed(.glmFrames)
        }
    }

    /// `forced`: the family's rule for this request's forced call; nil for `auto`.
    private static func framed(
        parser: ToolCallFormat, forced: Family.Forced?, request: Request, switches: Switches
    ) -> ToolCallExposure {
        guard parser != .mimoV2, parser != .nemotron else { return .withheld(.parserOfAnotherFamily) }
        switch forced {
        case nil:
            break
        case .withheld(let reason):
            return .withheld(.family(reason))
        case .streams(let strategy):
            guard request.clientStreams else { return .withheld(.clientDoesNotStream) }
            guard request.forcedStrategy == strategy, let family = forcedSwitch(of: strategy) else {
                return .withheld(.forcedByAnotherStrategy)
            }
            guard switches.forced[family] else { return .withheld(.switchedOff(.forcedToolCalls)) }
        }
        return parserFrames(parser)
    }

    /// The switch that governs the forced calls a strategy enforces; nil for
    /// `.none`, which forces no call.
    private static func forcedSwitch(
        of strategy: ToolChoiceEnforcementPolicy.Strategy
    ) -> ToolStreamPreparation.ForcedCalls.Family? {
        switch strategy {
        case .gemmaGrammar: .gemma
        case .structuredPostValidation: .qwen
        case .harmonyFraming: .gptOSS
        case .none: nil
        }
    }

    private static func nativeChannel(
        parser: ToolCallFormat, forced: Bool, request: Request, switches: Switches
    ) -> ToolCallExposure {
        guard switches.native else { return .withheld(.switchedOff(.nativeToolCalls)) }
        guard request.clientStreams else { return .withheld(.clientDoesNotStream) }
        guard !forced || switches.forced[.native] else { return .withheld(.switchedOff(.forcedToolCalls)) }
        return parserFrames(parser)
    }

    private static func parserFrames(_ parser: ToolCallFormat) -> ToolCallExposure {
        ToolCallStreamingOptions.supports(parser) ? .streamed(.parserFrames) : .withheld(.parserRendersNoFragments)
    }
}
