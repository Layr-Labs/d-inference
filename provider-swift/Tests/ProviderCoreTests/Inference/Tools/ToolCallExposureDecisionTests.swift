// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// `ToolCallExposure`: one decision per served model type, and one outcome
/// for every type, tool choice and client. `ToolCallExposurePinTests` holds
/// the same outcomes as each owner's handler and output show them.
@Suite("Tool-call exposure: the decision per served model type")
struct ToolCallExposureDecisionTests {
    private typealias Family = ToolCallExposure.Family

    /// Each served type's family for a build the catalog lists, on the
    /// scheduler's path.
    private static let pinned: [ServedModelType: String] = [
        .gemma4: "framed, forced calls stream under gemmaGrammar",
        .gemma4Text: "framed, forced calls stream under gemmaGrammar",
        .gptOSS: "framed, forced calls stream under harmonyFraming",
        .qwen35: "framed, forced calls stream under structuredPostValidation",
        .qwen35MoE: "framed, forced calls stream under structuredPostValidation",
        .qwen3VLMoE: "framed, forced calls withheld",
        .prismHadamardQwen35: "native channel, qwen3_5 parser",
        .mimoV2: "native channel, mimo_v2 parser",
        .nemotronH: "native channel, nemotron parser",
        .nemotronHOmni: "framed, forced calls withheld",
        .glm5Next: "GLM",
        .qwen4Exp: "withheld",
        .qwen4ExpText: "withheld",
        .diffusionGemma: "withheld",
        .flint: "withheld",
    ]

    /// A listed build of each type whose family depends on the build.
    private static func listedModelID(_ type: ServedModelType) -> String? {
        switch type {
        case .prismHadamardQwen35: "ternary-bonsai-2-27b"
        case .nemotronH: EngineV2SupportedModels.nemotron35LightningRegistryModelID
        case .nemotronHOmni: NemotronSuperLocalBinding.modelID
        case .gptOSS, .gemma4, .gemma4Text, .diffusionGemma, .qwen35, .qwen35MoE, .qwen3VLMoE, .qwen4Exp,
            .qwen4ExpText, .flint, .mimoV2, .glm5Next:
            nil
        }
    }

    private static func summary(_ family: Family) -> String {
        switch family {
        case .framed(.streams(let forced)): "framed, forced calls stream under \(forced)"
        case .framed(.withheld): "framed, forced calls withheld"
        case .nativeChannel(let parser): "native channel, \(parser.rawValue) parser"
        case .glm: "GLM"
        case .superOwner: "Super's owner"
        case .withheld: "withheld"
        }
    }

    @Test("every served model type has its family pinned here, with a reason where calls are withheld")
    func everyServedTypeIsDecided() {
        #expect(Set(Self.pinned.keys) == Set(ServedModelType.allCases))
        for type in ServedModelType.allCases {
            let family = Family.served(type, modelID: Self.listedModelID(type))
            #expect(Self.summary(family) == Self.pinned[type], "\(type)")
            switch family {
            case .withheld(let reason), .framed(.withheld(let reason)):
                #expect(!reason.isEmpty, "\(type)")
            case .framed(.streams), .nativeChannel, .glm, .superOwner:
                break
            }
        }
    }

    @Test("a build the catalog does not list is a framed family whose forced calls are withheld")
    func unlistedBuilds() {
        for type in [ServedModelType.prismHadamardQwen35, .nemotronH] {
            #expect(Self.summary(Family.served(type, modelID: "another-build")) == "framed, forced calls withheld")
            #expect(Self.summary(Family.served(type, modelID: nil)) == "framed, forced calls withheld")
        }
        #expect(Family.served(.prismHadamardQwen35, modelID: Bonsai9BModelPolicy.modelID)
            == .nativeChannel(parser: .qwen35))
    }

    /// A served type under another spelling, for a listed build: the family
    /// the replaced rules gave such a string. Spelled out so that a change
    /// to how a spelling is read shows up as a diff of this table.
    private static let respelled: [ServedModelType: String] = [
        .gemma4: "framed, forced calls stream under gemmaGrammar",
        .gemma4Text: "framed, forced calls stream under gemmaGrammar",
        .gptOSS: "framed, forced calls stream under harmonyFraming",
        .qwen35: "framed, forced calls stream under structuredPostValidation",
        .qwen35MoE: "framed, forced calls stream under structuredPostValidation",
        .qwen3VLMoE: "framed, forced calls withheld",
        .prismHadamardQwen35: "withheld",
        .mimoV2: "framed, forced calls withheld",
        .nemotronH: "withheld",
        .nemotronHOmni: "framed, forced calls withheld",
        .glm5Next: "framed, forced calls withheld",
        .qwen4Exp: "withheld",
        .qwen4ExpText: "withheld",
        .diffusionGemma: "withheld",
        .flint: "framed, forced calls withheld",
    ]

    @Test("a served type under another letter case or with surrounding whitespace has the family pinned here")
    func otherSpellings() {
        #expect(Set(Self.respelled.keys) == Set(ServedModelType.allCases))
        for type in ServedModelType.allCases {
            let id = Self.listedModelID(type)
            let spellings = [
                type.rawValue.uppercased(), type.rawValue.prefix(1).uppercased() + type.rawValue.dropFirst(),
                " \(type.rawValue) ", "\t\(type.rawValue)\n",
            ]
            for spelling in spellings {
                #expect(ServedModelType(normalizing: spelling) == type, "\(spelling.debugDescription)")
                #expect(Self.summary(Family.of(.init(modelId: id, modelType: spelling))) == Self.respelled[type],
                    "\(spelling.debugDescription)")
            }
            #expect(Family.of(.init(modelId: id, modelType: type.rawValue)) == Family.served(type, modelID: id),
                "\(type)")
        }
        // An unlisted build is a framed family under any spelling.
        for spelling in ["NEMOTRON_H", " prism_hadamard_qwen35\n"] {
            #expect(Self.summary(Family.of(.init(modelId: "another-build", modelType: spelling)))
                == "framed, forced calls withheld", "\(spelling.debugDescription)")
        }
    }

    /// The supported set and this decision read a type through one
    /// normalisation (`ServedModelType.init(normalizing:)`), so a string the
    /// supported set admits is never an unserved type here.
    @Test("every string the supported set admits names a served type for the exposure decision")
    func oneNormalisation() {
        var strings: [String?] = [nil, "", "  ", "llama", "gemma4_vision", "qwen3_5x", "glm5_next_text"]
        for type in ServedModelType.allCases {
            strings += [type.rawValue, type.rawValue.uppercased(), " \(type.rawValue)\n"]
        }
        var admitted = 0
        for string in strings where EngineV2SupportedModels.isSupported(modelType: string) {
            admitted += 1
            #expect(ServedModelType(normalizing: string) != nil, "\(string.debugDescription)")
        }
        // Ten types are admitted under any spelling, MiMo and Flint as declared only.
        #expect(admitted == 10 * 3 + 2)
    }

    /// A string that names no served type: GLM's component types take GLM's
    /// family, and every other one is framed, its forced calls streaming
    /// under the Gemma grammar alone (`gemma4_vision`, or no type and a
    /// `gemma-4` model id, select it).
    @Test("a type that names no served type is GLM's for its component types, and framed otherwise")
    func unservedTypes() {
        for modelType in ["glm5_next_text", "glm5_next_mtp"] {
            #expect(Family.of(.init(modelId: "glm-5.3-flash", modelType: modelType)) == .glm, "\(modelType)")
        }
        let framed: [String?] = [nil, "", "llama", "qwen3", "gemma4_vision", "glm5_next_vision", "GLM5_NEXT_TEXT"]
        for modelType in framed {
            #expect(Self.summary(Family.of(.init(modelId: "gemma-4-qwen3.5", modelType: modelType)))
                == "framed, forced calls stream under gemmaGrammar", "\(modelType.debugDescription)")
        }
    }

    // MARK: - Every type, tool choice and client

    private enum Choice: String, CaseIterable {
        case auto, required, named

        var mode: ToolConstraintMode {
            switch self {
            case .auto: .auto
            case .required: .required
            case .named: .named("get_weather")
            }
        }
    }

    private static let everySwitchOn = ToolCallExposure.Switches(
        toolCalls: true, forced: .all, native: true, glm: true)

    private static func switches(_ change: (inout ToolCallExposure.Switches) -> Void) -> ToolCallExposure.Switches {
        var switches = everySwitchOn
        change(&switches)
        return switches
    }

    /// What enforces a forced choice for a type's listed build, as the
    /// scheduler resolves it; `.none` where nothing does.
    private static func forcedStrategy(_ type: ServedModelType, _ choice: Choice) -> ToolChoiceEnforcementPolicy.Strategy {
        guard type != .nemotronHOmni else { return .none }
        let context = ChatTemplateFixContext(modelId: listedModelID(type), modelType: type.rawValue)
        return (try? ToolChoiceEnforcementPolicy.forcedStrategy(mode: choice.mode, modelContext: context)) ?? .none
    }

    /// The owner that serves the type, and the parser its requests resolve.
    private static func exposure(
        _ type: ServedModelType, _ choice: Choice, clientStreams: Bool, rendersFragments: Bool = true,
        offersTools: Bool = true, json: Bool = false, parser: ToolCallFormat? = nil,
        switches: ToolCallExposure.Switches = everySwitchOn
    ) throws -> ToolCallExposure {
        let family: Family = type == .nemotronHOmni ? .superOwner : .served(type, modelID: listedModelID(type))
        return ToolCallExposure.resolve(
            family: family,
            parser: try parser ?? ServerToolParser.resolve(requested: nil, modelType: type.rawValue),
            request: .init(mode: choice.mode, clientStreams: clientStreams, rendersFragments: rendersFragments,
                offersTools: offersTools, withholdsJSONAnswer: json, forcedStrategy: forcedStrategy(type, choice)),
            switches: switches)
    }

    private static func tag(_ exposure: ToolCallExposure) -> String {
        switch exposure {
        case .streamed(.parserFrames): "streamed, parser frames"
        case .streamed(.glmFrames): "streamed, GLM frames"
        case .withheld(.switchedOff(let off)): "withheld, \(off) off"
        case .withheld(.surfaceRendersNoFragments): "withheld, no fragments"
        case .withheld(.toolChoiceNone): "withheld, tool_choice none"
        case .withheld(.noToolsOffered): "withheld, no tools"
        case .withheld(.clientDoesNotStream): "withheld, client does not stream"
        case .withheld(.jsonAnswerWithheld): "withheld, JSON answer"
        case .withheld(.parserRendersNoFragments): "withheld, parser renders no fragments"
        case .withheld(.parserOfAnotherFamily): "withheld, another family's parser"
        case .withheld(.forcedByAnotherStrategy): "withheld, forced by another strategy"
        case .withheld(.family): "withheld, family"
        }
    }

    /// Served types whose calls a streaming client still receives whole, each
    /// with the tool choices held and why. This list may only shrink: a type
    /// added to `ServedModelType`, or a choice withheld again, fails the test
    /// below until it streams or is listed here on purpose.
    private static let withheldFromAStreamingClient: [ServedModelType: [Choice: String]] = [
        .qwen3VLMoE: [.required: "withheld, family", .named: "withheld, family"],
        .qwen4Exp: [.auto: "withheld, family", .required: "withheld, family", .named: "withheld, family"],
        .qwen4ExpText: [.auto: "withheld, family", .required: "withheld, family", .named: "withheld, family"],
        .diffusionGemma: [.auto: "withheld, family", .required: "withheld, family", .named: "withheld, family"],
        .flint: [.auto: "withheld, family", .required: "withheld, family", .named: "withheld, family"],
    ]

    @Test("a served family streams its calls to a client that streams, except the listed cells")
    func servedFamiliesStreamToAStreamingClient() throws {
        for type in ServedModelType.allCases {
            for choice in Choice.allCases {
                let exposure = try Self.exposure(type, choice, clientStreams: true)
                if let held = Self.withheldFromAStreamingClient[type]?[choice] {
                    #expect(Self.tag(exposure) == held, "\(type) \(choice)")
                } else {
                    #expect(exposure.streams, "\(type) \(choice): \(Self.tag(exposure))")
                }
            }
        }
    }

    /// The framed families' `auto` calls leave as fragments on any surface
    /// that renders them: the coordinator path serves every request as a
    /// stream and reassembles a complete response.
    private static let streamedWithoutAStreamingClient: Set<ServedModelType> = [
        .gemma4, .gemma4Text, .gptOSS, .qwen35, .qwen35MoE, .qwen3VLMoE,
    ]

    @Test("a client that does not stream gets complete calls, except the framed families' `auto` calls")
    func clientsThatDoNotStream() throws {
        for type in ServedModelType.allCases {
            for choice in Choice.allCases {
                let exposure = try Self.exposure(type, choice, clientStreams: false)
                let streams = choice == .auto && Self.streamedWithoutAStreamingClient.contains(type)
                #expect(exposure.streams == streams, "\(type) \(choice): \(Self.tag(exposure))")
            }
        }
    }

    @Test("GLM's frames are read by the router; every other family's by its parser")
    func sources() throws {
        for type in ServedModelType.allCases {
            guard case .streamed(let source) = try Self.exposure(type, .auto, clientStreams: true) else { continue }
            #expect(source == (type == .glm5Next ? .glmFrames : .parserFrames), "\(type)")
        }
    }

    @Test("each withheld outcome names what withheld it")
    func reasons() throws {
        func tag(_ type: ServedModelType, _ choice: Choice = .auto, clientStreams: Bool = true,
                 rendersFragments: Bool = true, offersTools: Bool = true, json: Bool = false,
                 parser: ToolCallFormat? = nil, switches: ToolCallExposure.Switches = Self.everySwitchOn) throws -> String {
            Self.tag(try Self.exposure(type, choice, clientStreams: clientStreams, rendersFragments: rendersFragments,
                offersTools: offersTools, json: json, parser: parser, switches: switches))
        }
        #expect(try tag(.gemma4, switches: Self.switches { $0.toolCalls = false }) == "withheld, toolCalls off")
        #expect(try tag(.gemma4, rendersFragments: false) == "withheld, no fragments")
        #expect(try tag(.gemma4, .required, clientStreams: false) == "withheld, client does not stream")
        #expect(try tag(.gemma4, .required, switches: Self.switches { $0.forced.gemma = false })
            == "withheld, forcedToolCalls off")
        #expect(try tag(.qwen35, parser: .xmlFunction) == "withheld, parser renders no fragments")
        #expect(try tag(.qwen35, parser: .nemotron) == "withheld, another family's parser")
        #expect(try tag(.nemotronH, parser: .json) == "withheld, another family's parser")
        #expect(try tag(.mimoV2, clientStreams: false) == "withheld, client does not stream")
        #expect(try tag(.mimoV2, switches: Self.switches { $0.native = false }) == "withheld, nativeToolCalls off")
        #expect(try tag(.mimoV2, .named, switches: Self.switches { $0.forced.native = false })
            == "withheld, forcedToolCalls off")
        #expect(try tag(.glm5Next, switches: Self.switches { $0.glm = false }) == "withheld, glmToolCalls off")
        #expect(try tag(.glm5Next, json: true) == "withheld, JSON answer")
        #expect(try tag(.glm5Next, offersTools: false) == "withheld, no tools")
        #expect(try tag(.nemotronHOmni, json: true) == "withheld, JSON answer")
        #expect(try tag(.nemotronHOmni, offersTools: false) == "withheld, no tools")
        #expect(ToolCallExposure.resolve(
            family: .served(.gemma4, modelID: nil), parser: .gemma,
            request: .init(mode: .none, clientStreams: true, rendersFragments: true, offersTools: true,
                withholdsJSONAnswer: false, forcedStrategy: .none),
            switches: Self.everySwitchOn) == .withheld(.toolChoiceNone))
    }

    /// A framed family's forced calls stream only when the strategy the
    /// family names is what enforces the request: an id or a spelling that
    /// selects another one keeps them withheld.
    @Test("a forced call streams under its family's strategy alone")
    func forcedStrategies() {
        func exposure(_ family: Family, _ strategy: ToolChoiceEnforcementPolicy.Strategy, parser: ToolCallFormat)
            -> ToolCallExposure
        {
            ToolCallExposure.resolve(
                family: family, parser: parser,
                request: .init(mode: .required, clientStreams: true, rendersFragments: true, offersTools: true,
                    withholdsJSONAnswer: false, forcedStrategy: strategy),
                switches: Self.everySwitchOn)
        }
        let families: [(Family, ToolCallFormat, ToolChoiceEnforcementPolicy.Strategy)] = [
            (.served(.gemma4, modelID: nil), .gemma, .gemmaGrammar),
            (.served(.gptOSS, modelID: nil), .harmony, .harmonyFraming),
            (.served(.qwen35, modelID: nil), .qwen35, .structuredPostValidation),
        ]
        let strategies: [ToolChoiceEnforcementPolicy.Strategy] = [
            .none, .gemmaGrammar, .structuredPostValidation, .harmonyFraming,
        ]
        for (family, parser, own) in families {
            for strategy in strategies {
                #expect(exposure(family, strategy, parser: parser)
                    == (strategy == own ? .streamed(.parserFrames) : .withheld(.forcedByAnotherStrategy)),
                    "\(own) under \(strategy)")
            }
        }
    }

    /// A type the engine does not serve keeps the rule every type had before
    /// the families were told apart: `auto` calls stream where the parser
    /// renders fragments, and a forced call only under the Gemma grammar.
    @Test("an unserved type streams `auto` calls, and forced ones under the Gemma grammar alone")
    func unservedExposure() {
        let family = Family.unserved(.init(modelId: "unknown", modelType: "llama"))
        func exposure(_ choice: Choice, _ strategy: ToolChoiceEnforcementPolicy.Strategy = .none,
                      parser: ToolCallFormat = .json) -> ToolCallExposure {
            ToolCallExposure.resolve(
                family: family, parser: parser,
                request: .init(mode: choice.mode, clientStreams: true, rendersFragments: true, offersTools: true,
                    withholdsJSONAnswer: false, forcedStrategy: strategy),
                switches: Self.everySwitchOn)
        }
        #expect(exposure(.auto) == .streamed(.parserFrames))
        #expect(exposure(.required, .gemmaGrammar, parser: .gemma) == .streamed(.parserFrames))
        #expect(exposure(.required, .structuredPostValidation) == .withheld(.forcedByAnotherStrategy))
        #expect(exposure(.named, .harmonyFraming) == .withheld(.forcedByAnotherStrategy))
        #expect(exposure(.auto, parser: .nemotron) == .withheld(.parserOfAnotherFamily))
        #expect(exposure(.auto, parser: .glm5) == .withheld(.parserRendersNoFragments))
    }
}
