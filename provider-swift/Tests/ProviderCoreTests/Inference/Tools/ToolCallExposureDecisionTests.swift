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
        .gemma4: "framed, forced calls stream under gemma",
        .gemma4Text: "framed, forced calls stream under gemma",
        .gptOSS: "framed, forced calls stream under gptOSS",
        .qwen35: "framed, forced calls stream under qwen",
        .qwen35MoE: "framed, forced calls stream under qwen",
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

    /// The family is read from the type exactly as config.json declares it,
    /// the only spelling whose model loads (`ModelTypeRegistry`).
    @Test("a type that is not a served declaration is the unserved family")
    func undeclaredTypes() {
        let undeclared: [String?] = [
            nil, "", "llama", "qwen3", "gemma4_vision", "glm5_next_text", "glm5_next_mtp", "GEMMA4", " gemma4 ",
            "Qwen3_5", "MIMO_V2", "nemotron_h ",
        ]
        for modelType in undeclared {
            #expect(Family.of(.init(modelId: "gemma-4-qwen3.5", modelType: modelType)) == Family.unserved,
                "\(modelType.debugDescription)")
        }
        for type in ServedModelType.allCases {
            #expect(Family.of(.init(modelId: Self.listedModelID(type), modelType: type.rawValue))
                == Family.served(type, modelID: Self.listedModelID(type)), "\(type)")
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

    /// The owner that serves the type, and the parser its requests resolve.
    private static func exposure(
        _ type: ServedModelType, _ choice: Choice, clientStreams: Bool,
        switches: ToolCallExposure.Switches = .init()
    ) throws -> ToolCallExposure {
        let family: Family = type == .nemotronHOmni ? .superOwner : .served(type, modelID: listedModelID(type))
        return ToolCallExposure.resolve(
            family: family,
            parser: try ServerToolParser.resolve(requested: nil, modelType: type.rawValue),
            request: .init(mode: choice.mode, clientStreams: clientStreams, rendersFragments: true,
                offersTools: true, withholdsJSONAnswer: false),
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
                 parser: ToolCallFormat? = nil, switches: ToolCallExposure.Switches = .init()) throws -> String {
            let family: Family = type == .nemotronHOmni ? .superOwner : .served(type, modelID: Self.listedModelID(type))
            return Self.tag(ToolCallExposure.resolve(
                family: family,
                parser: try parser ?? ServerToolParser.resolve(requested: nil, modelType: type.rawValue),
                request: .init(mode: choice.mode, clientStreams: clientStreams, rendersFragments: rendersFragments,
                    offersTools: offersTools, withholdsJSONAnswer: json),
                switches: switches))
        }
        #expect(try tag(.gemma4, switches: .init(toolCalls: false)) == "withheld, toolCalls off")
        #expect(try tag(.gemma4, rendersFragments: false) == "withheld, no fragments")
        #expect(try tag(.gemma4, .required, clientStreams: false) == "withheld, client does not stream")
        #expect(try tag(.gemma4, .required, switches: .init(forced: .init(gemma: false)))
            == "withheld, forcedToolCalls off")
        #expect(try tag(.qwen35, parser: .xmlFunction) == "withheld, parser renders no fragments")
        #expect(try tag(.qwen35, parser: .nemotron) == "withheld, another family's parser")
        #expect(try tag(.nemotronH, parser: .json) == "withheld, another family's parser")
        #expect(try tag(.mimoV2, clientStreams: false) == "withheld, client does not stream")
        #expect(try tag(.mimoV2, switches: .init(native: false)) == "withheld, nativeToolCalls off")
        #expect(try tag(.mimoV2, .named, switches: .init(forced: .init(native: false)))
            == "withheld, forcedToolCalls off")
        #expect(try tag(.glm5Next, switches: .init(glm: false)) == "withheld, glmToolCalls off")
        #expect(try tag(.glm5Next, json: true) == "withheld, JSON answer")
        #expect(try tag(.glm5Next, offersTools: false) == "withheld, no tools")
        #expect(try tag(.nemotronHOmni, json: true) == "withheld, JSON answer")
        #expect(try tag(.nemotronHOmni, offersTools: false) == "withheld, no tools")
        #expect(ToolCallExposure.resolve(
            family: .served(.gemma4, modelID: nil), parser: .gemma,
            request: .init(mode: .none, clientStreams: true, rendersFragments: true, offersTools: true,
                withholdsJSONAnswer: false),
            switches: .init()) == .withheld(.toolChoiceNone))
    }

    /// A type the engine does not serve keeps the rule every type had before
    /// the families were told apart: `auto` calls stream where the parser
    /// renders fragments, and no forced call does.
    @Test("an unserved type streams `auto` calls only")
    func unservedTypes() {
        func exposure(_ choice: Choice, parser: ToolCallFormat = .json) -> ToolCallExposure {
            ToolCallExposure.resolve(
                family: .unserved, parser: parser,
                request: .init(mode: choice.mode, clientStreams: true, rendersFragments: true, offersTools: true,
                    withholdsJSONAnswer: false),
                switches: .init())
        }
        #expect(exposure(.auto) == .streamed(.parserFrames))
        #expect(Self.tag(exposure(.required)) == "withheld, family")
        #expect(Self.tag(exposure(.named)) == "withheld, family")
        #expect(exposure(.auto, parser: .nemotron) == .withheld(.parserOfAnotherFamily))
        #expect(exposure(.auto, parser: .glm5) == .withheld(.parserRendersNoFragments))
    }
}
