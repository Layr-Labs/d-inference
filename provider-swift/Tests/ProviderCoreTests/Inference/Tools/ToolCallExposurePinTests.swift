// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Whether a tool call leaves while it is generated or only once complete,
/// read where each owner decides it: the scheduler's handler and router
/// (`ToolStreamPreparation.makeHandler`, `streamsGLMCalls`,
/// `NativeToolStreamRouter.streamsToolCalls`) and Nemotron 3.5 Super's own
/// output (`NemotronSuperLocalOutput`).
///
/// Every outcome is spelled out here, not read from the policy, so a change
/// that moves a family, a mode or a switch shows up as a diff of this file.
@Suite("Tool-call exposure: the outcome for every family, mode, client and switch")
struct ToolCallExposurePinTests {
    /// One build as a request names it.
    struct Build: Sendable, CustomTestStringConvertible {
        let name: String
        let modelType: String?
        let model: String
        /// `auto`, `required` and a named function to a client that streams,
        /// then to one that does not, on a surface that renders fragments and
        /// with every switch on: `S` streamed, `w` withheld, `x` refused
        /// before any output (the build serves no such forced choice).
        let pinned: String
        /// The build above whose switches govern this row; nil for its own.
        var switchedWith: String? = nil
        var served: ServedModelType? { modelType.flatMap(ServedModelType.init(rawValue:)) }
        var switchGroup: String { switchedWith ?? name }
        var testDescription: String { name }
    }

    static let builds: [Build] = [
        .init(name: "Gemma 4", modelType: "gemma4", model: "gemma-4-26b-qat-4bit", pinned: "SSS Sww"),
        .init(name: "Gemma 4 text", modelType: "gemma4_text", model: "gemma-4-26b-text", pinned: "SSS Sww"),
        .init(name: "GPT-OSS", modelType: "gpt_oss", model: "gpt-oss-20b", pinned: "SSS Sww"),
        .init(name: "Qwen 3.5 and 3.8 dense", modelType: "qwen3_5", model: "Qwen3.5-9B", pinned: "SSS Sww"),
        .init(name: "Qwen 3.5 and 3.6 MoE", modelType: "qwen3_5_moe", model: "qwen3.5-35b-a3b", pinned: "SSS Sww"),
        .init(name: "Qwen3-VL", modelType: "qwen3_vl_moe", model: "qwen3-vl-30b-a3b", pinned: "Sxx Sxx"),
        .init(name: "Bonsai 2 27B", modelType: "prism_hadamard_qwen35", model: "ternary-bonsai-2-27b",
              pinned: "SSS www"),
        .init(name: "Bonsai 2 9B", modelType: "prism_hadamard_qwen35", model: Bonsai9BModelPolicy.modelID,
              pinned: "SSS www"),
        .init(name: "another Prism build", modelType: "prism_hadamard_qwen35", model: "another-prism-build",
              pinned: "Sww Sww"),
        .init(name: "MiMo V2.6", modelType: "mimo_v2", model: "mimo-v2.6-flash-mopd", pinned: "SSS www"),
        .init(name: "Nemotron 3.5 Lightning", modelType: "nemotron_h", model: "nvidia-nemotron-3.5-lightning",
              pinned: "SSS www"),
        .init(name: "another Nemotron build", modelType: "nemotron_h", model: "another-nemotron-build",
              pinned: "wxx wxx"),
        .init(name: "Nemotron 3.5 Super on the scheduler", modelType: "nemotron_h_omni",
              model: NemotronSuperLocalBinding.modelID, pinned: "wxx wxx"),
        .init(name: "GLM-5.3-Flash", modelType: "glm5_next", model: GLM5NextCoordinatorServing.catalogModelID,
              pinned: "SSS www"),
        .init(name: "Qwen 4", modelType: "qwen4_exp", model: "qwen4-exp", pinned: "www www"),
        .init(name: "Qwen 4 text", modelType: "qwen4_exp_text", model: "qwen4-exp-text", pinned: "www www"),
        .init(name: "diffusion Gemma", modelType: "diffusion_gemma", model: "diffusion-gemma", pinned: "www www"),
        .init(name: "Flint", modelType: "flint", model: "flint", pinned: "www www"),
        // Types the engine does not serve: no model of one loads, a test registry can name one.
        .init(name: "a type that is not served", modelType: "llama", model: "llama-3", pinned: "Sxx Sxx"),
        .init(name: "no type", modelType: nil, model: "unknown", pinned: "Sxx Sxx"),
    ]

    /// The served types under other spellings, and types and ids outside the
    /// served set. The supported set admits a type in any letter case and
    /// with surrounding whitespace (`EngineV2SupportedModels.isSupported(modelType:)`),
    /// and a cluster pair's slot takes the `model_type` of its pinned
    /// config.json unchecked. No model of such a spelling is known to load
    /// (the SDK's registry is keyed by the type as declared), but nothing
    /// rules these strings out either, so the tool path does not rely on the
    /// spelling. Each rule that reads the type has its own tolerance; the
    /// outcomes below are what those rules give together, kept as they are.
    static let otherSpellings: [Build] = [
        // Letter case alone. The parser is still inferred from the type.
        .init(name: "GEMMA4", modelType: "GEMMA4", model: "gemma-4-26b-qat-4bit", pinned: "SSS Sww",
              switchedWith: "Gemma 4"),
        .init(name: "Gemma4_Text", modelType: "Gemma4_Text", model: "gemma-4-26b-text", pinned: "SSS Sww",
              switchedWith: "Gemma 4 text"),
        .init(name: "GPT_OSS", modelType: "GPT_OSS", model: "gpt-oss-20b", pinned: "SSS Sww",
              switchedWith: "GPT-OSS"),
        .init(name: "Qwen3_5", modelType: "Qwen3_5", model: "Qwen3.5-9B", pinned: "SSS Sww",
              switchedWith: "Qwen 3.5 and 3.8 dense"),
        .init(name: "QWEN3_5_MOE", modelType: "QWEN3_5_MOE", model: "qwen3.5-35b-a3b", pinned: "SSS Sww",
              switchedWith: "Qwen 3.5 and 3.6 MoE"),
        .init(name: "QWEN3_VL_MOE", modelType: "QWEN3_VL_MOE", model: "qwen3-vl-30b-a3b", pinned: "Sxx Sxx"),
        // A listed native-channel build under another spelling keeps its
        // native framing but not its stream: the stream reads the type exactly.
        .init(name: "PRISM_HADAMARD_QWEN35, Bonsai 2 27B", modelType: "PRISM_HADAMARD_QWEN35",
              model: "ternary-bonsai-2-27b", pinned: "www www"),
        .init(name: "PRISM_HADAMARD_QWEN35, Bonsai 2 9B", modelType: "PRISM_HADAMARD_QWEN35",
              model: Bonsai9BModelPolicy.modelID, pinned: "www www"),
        .init(name: "PRISM_HADAMARD_QWEN35, another build", modelType: "PRISM_HADAMARD_QWEN35",
              model: "another-prism-build", pinned: "Sww Sww"),
        .init(name: "NEMOTRON_H, Lightning", modelType: "NEMOTRON_H", model: "nvidia-nemotron-3.5-lightning",
              pinned: "www www"),
        .init(name: "NEMOTRON_H, another build", modelType: "NEMOTRON_H", model: "another-nemotron-build",
              pinned: "wxx wxx"),
        .init(name: "NEMOTRON_H_OMNI", modelType: "NEMOTRON_H_OMNI", model: NemotronSuperLocalBinding.modelID,
              pinned: "wxx wxx"),
        .init(name: "MIMO_V2", modelType: "MIMO_V2", model: "mimo-v2.6-flash-mopd", pinned: "wxx wxx"),
        .init(name: "GLM5_NEXT", modelType: "GLM5_NEXT", model: GLM5NextCoordinatorServing.catalogModelID,
              pinned: "wxx wxx"),
        .init(name: "QWEN4_EXP", modelType: "QWEN4_EXP", model: "qwen4-exp", pinned: "www www"),
        .init(name: "Qwen4_Exp_Text", modelType: "Qwen4_Exp_Text", model: "qwen4-exp-text", pinned: "www www"),
        .init(name: "DIFFUSION_GEMMA", modelType: "DIFFUSION_GEMMA", model: "diffusion-gemma", pinned: "www www"),
        .init(name: "FLINT", modelType: "FLINT", model: "flint", pinned: "wxx wxx"),
        // Surrounding whitespace. No parser is inferred from such a type, so
        // the request parses JSON frames unless it names a parser.
        .init(name: "gemma4, padded", modelType: " gemma4\n", model: "gemma-4-26b-qat-4bit", pinned: "Sxx Sxx"),
        .init(name: "gemma4_text, padded", modelType: " gemma4_text\n", model: "gemma-4-26b-text",
              pinned: "Sxx Sxx"),
        .init(name: "gpt_oss, padded", modelType: " gpt_oss\n", model: "gpt-oss-20b", pinned: "Sxx Sxx"),
        .init(name: "qwen3_5, padded", modelType: " qwen3_5\n", model: "Qwen3.5-9B", pinned: "Sxx Sxx"),
        .init(name: "qwen3_5_moe, padded", modelType: " qwen3_5_moe\n", model: "qwen3.5-35b-a3b",
              pinned: "Sxx Sxx"),
        .init(name: "qwen3_vl_moe, padded", modelType: " qwen3_vl_moe\n", model: "qwen3-vl-30b-a3b",
              pinned: "Sxx Sxx"),
        .init(name: "prism_hadamard_qwen35, padded, Bonsai 2 27B", modelType: " prism_hadamard_qwen35\n",
              model: "ternary-bonsai-2-27b", pinned: "wxx wxx"),
        .init(name: "prism_hadamard_qwen35, padded, another build", modelType: " prism_hadamard_qwen35\n",
              model: "another-prism-build", pinned: "Sxx Sxx"),
        .init(name: "nemotron_h, padded, Lightning", modelType: " nemotron_h\n",
              model: "nvidia-nemotron-3.5-lightning", pinned: "wxx wxx"),
        .init(name: "nemotron_h, padded, another build", modelType: " nemotron_h\n",
              model: "another-nemotron-build", pinned: "Sxx Sxx"),
        .init(name: "nemotron_h_omni, padded", modelType: " nemotron_h_omni\n",
              model: NemotronSuperLocalBinding.modelID, pinned: "Sxx Sxx"),
        .init(name: "mimo_v2, padded", modelType: " mimo_v2\n", model: "mimo-v2.6-flash-mopd", pinned: "Sxx Sxx"),
        .init(name: "glm5_next, padded", modelType: " glm5_next\n", model: GLM5NextCoordinatorServing.catalogModelID,
              pinned: "Sxx Sxx"),
        .init(name: "qwen4_exp, padded", modelType: " qwen4_exp\n", model: "qwen4-exp", pinned: "wxx wxx"),
        .init(name: "qwen4_exp_text, padded", modelType: " qwen4_exp_text\n", model: "qwen4-exp-text",
              pinned: "wxx wxx"),
        .init(name: "diffusion_gemma, padded", modelType: " diffusion_gemma\n", model: "diffusion-gemma",
              pinned: "wxx wxx"),
        .init(name: "flint, padded", modelType: " flint\n", model: "flint", pinned: "Sxx Sxx"),
        // Types outside the served set that a rule still names: Gemma's
        // vision component takes the Gemma grammar, GLM's components GLM's stream.
        .init(name: "gemma4_vision", modelType: "gemma4_vision", model: "gemma-4-vision", pinned: "SSS Sww",
              switchedWith: "Gemma 4"),
        .init(name: "glm5_next_text", modelType: "glm5_next_text", model: GLM5NextCoordinatorServing.catalogModelID,
              pinned: "SSS www", switchedWith: "GLM-5.3-Flash"),
        .init(name: "glm5_next_mtp", modelType: "glm5_next_mtp", model: GLM5NextCoordinatorServing.catalogModelID,
              pinned: "SSS www", switchedWith: "GLM-5.3-Flash"),
        // No type: the model id alone selects the Gemma grammar (`gemma-4`)
        // or Qwen's structured forcing (`qwen3.5`); neither parser is
        // inferred, so a forced choice is refused unless the request names it.
        .init(name: "no type, a gemma-4 id", modelType: nil, model: "gemma-4-26b-qat-4bit", pinned: "Sxx Sxx"),
        .init(name: "no type, a qwen3.5 id", modelType: nil, model: "Qwen3.5-9B", pinned: "Sxx Sxx"),
        // A served type under an id that names another family.
        .init(name: "gpt_oss under a qwen3.5 id", modelType: "gpt_oss", model: "qwen3.5-oss", pinned: "Sxx Sxx"),
    ]

    /// Every row: the builds as declared, then the other spellings.
    static let rows = builds + otherSpellings

    /// Super as its own owner serves it; read from its output's events.
    static let superOwnerPinned = "SSS www"

    enum Choice: String, CaseIterable, Sendable {
        case auto = #""auto""#
        case required = #""required""#
        case named = #"{"type":"function","function":{"name":"get_weather"}}"#
        case none = #""none""#

        var forced: Bool { self == .required || self == .named }
    }

    /// The six cells of a pinned row, in its order.
    static let cells: [(choice: Choice, clientStreams: Bool)] = [
        (.auto, true), (.required, true), (.named, true), (.auto, false), (.required, false), (.named, false),
    ]

    static let tools = #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}},{"type":"function","function":{"name":"write_file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]"#

    /// The switches as the provider job reads them; each defaults to on.
    struct Switches: Sendable {
        var toolCalls = true
        var forced = ToolStreamPreparation.ForcedCalls.all
        var native = true
        var glm = true
    }

    static func body(model: String, choice: Choice, clientStreams: Bool, tools: String? = tools, extra: String = "")
        -> Data
    {
        Data((#"{"model":""# + model + #"","messages":[{"role":"user","content":"q"}],"stream":"#
            + (clientStreams ? "true" : "false") + (tools.map { #","tools":"# + $0 } ?? "")
            + #","tool_choice":"# + choice.rawValue + (extra.isEmpty ? "" : "," + extra) + "}").utf8)
    }

    /// The scheduler's outcome for one request: what its handler and router
    /// resolve, as `prepareCompletion` builds them.
    static func scheduler(
        _ build: Build, _ choice: Choice, clientStreams: Bool, rendersFragments: Bool = true,
        switches: Switches = .init(), parser: String? = nil, tools: String? = tools, extra: String = ""
    ) -> Character {
        do {
            var request = try ProviderLoop.decodeOpenAIRequest(
                body(model: build.model, choice: choice, clientStreams: clientStreams, tools: tools, extra: extra))
            request.streamToolCallDeltas = rendersFragments
            request.toolCallParser = parser
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: build.modelType)
            let handler = try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: build.modelType,
                streamToolCalls: switches.toolCalls, streamForcedToolCalls: switches.forced,
                streamNativeToolCalls: switches.native)
            let streamsGLMCalls = handler?.format == .glm5
                && ToolStreamPreparation.streamsGLMCalls(
                    request: request, prepared: prepared, modelType: build.modelType,
                    streamToolCalls: switches.toolCalls, streamGLMToolCalls: switches.glm,
                    streamForcedToolCalls: switches.forced)
            let router = NativeToolStreamRouter(
                handler: handler, requiresToolCall: prepared.requiresToolCall, nativePrefix: nil,
                tools: prepared.tools?.map { $0.toolSpec() }, streamedCalls: prepared,
                streamsGLMCalls: streamsGLMCalls)
            return router.streamsToolCalls ? "S" : "w"
        } catch {
            return "x"
        }
    }

    /// Super's own outcome: whether a call it wrote leaves as fragments.
    static func superOwner(
        _ choice: Choice, clientStreams: Bool, rendersFragments: Bool = true, ownerStreams: Bool = true,
        native: Bool = true, forced: Bool = true, tools: String? = tools, extra: String = ""
    ) throws -> Character {
        let body = body(model: NemotronSuperLocalBinding.modelID, choice: choice, clientStreams: clientStreams,
            tools: tools, extra: extra)
        var formatted = try OpenAIResponseFormatSupport.preparedRequest(ProviderLoop.decodeOpenAIRequest(body))
        formatted.stream = true
        formatted.streamToolCallDeltas = rendersFragments
        let plan = try NemotronSuperRequestPlan(body: body, formatted: formatted)
        var output = try NemotronSuperLocalOutput(
            plan: plan, streaming: ownerStreams, streamNativeToolCalls: native, streamForcedToolCalls: forced)
        let frame = "Done.</think><tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n"
            + "</function>\n</tool_call>"
        var events: [MLXServerGenerationEvent] = []
        do {
            events += try output.append(frame)
            events += try output.finish().events
        } catch {
            // `none` refuses the call itself; nothing left as a fragment.
        }
        return events.contains { if case .toolCallDelta = $0 { true } else { false } } ? "S" : "w"
    }

    private static func row(_ cell: (Choice, Bool) throws -> Character) rethrows -> String {
        let marks = try cells.map { try cell($0.choice, $0.clientStreams) }
        return String(marks[..<3]) + " " + String(marks[3...])
    }

    @Test("every served model type is pinned, and so are its listed and unlisted builds")
    func everyServedTypeIsPinned() {
        #expect(Set(Self.builds.compactMap(\.served)) == Set(ServedModelType.allCases))
        #expect(Set(Self.rows.map(\.name)).count == Self.rows.count, "row names are unique")
    }

    /// Each served type also has a row in another letter case and one with
    /// surrounding whitespace, read back by the supported set's own rule.
    @Test("every served model type is pinned under another letter case and with surrounding whitespace")
    func everyServedTypeIsPinnedRespelled() {
        func served(_ build: Build) -> ServedModelType? {
            build.modelType.flatMap {
                ServedModelType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
        let respelled = Self.otherSpellings.filter { served($0) != nil && $0.served == nil }
        let padded = respelled.filter { $0.modelType != $0.modelType?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let recased = respelled.filter { $0.modelType == $0.modelType?.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(Set(padded.compactMap(served)) == Set(ServedModelType.allCases))
        #expect(Set(recased.compactMap(served)) == Set(ServedModelType.allCases))
    }

    @Test("with every switch on, each build's calls leave exactly as pinned", arguments: rows)
    func defaultOutcome(build: Build) {
        #expect(Self.row { Self.scheduler(build, $0, clientStreams: $1) } == build.pinned)
    }

    @Test("Super's own owner streams its calls to a client that streams")
    func superOwnerDefaultOutcome() throws {
        #expect(try Self.row { try Self.superOwner($0, clientStreams: $1) } == Self.superOwnerPinned)
        // A complete (collected) response of the owner holds its calls.
        #expect(try Self.superOwner(.auto, clientStreams: true, ownerStreams: false) == "w")
    }

    @Test("`tool_choice: none` and a surface that renders no fragments stream nothing", arguments: rows)
    func nothingStreamsWithoutFragmentsOrAChoice(build: Build) throws {
        for clientStreams in [true, false] {
            #expect(Self.scheduler(build, .none, clientStreams: clientStreams) != "S")
            #expect(try Self.superOwner(.none, clientStreams: clientStreams) == "w")
            for choice in Choice.allCases {
                #expect(Self.scheduler(build, choice, clientStreams: clientStreams, rendersFragments: false) != "S")
                #expect(try Self.superOwner(choice, clientStreams: clientStreams, rendersFragments: false) == "w")
            }
        }
    }

    /// One switch turned off, and the cells of the default table it
    /// withholds: for the listed builds, its forced cells or all of them.
    struct SwitchOff: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let switches: Switches
        let builds: Set<String>
        let forcedOnly: Bool

        static let native: Set<String> = ["MiMo V2.6", "Nemotron 3.5 Lightning", "Bonsai 2 27B", "Bonsai 2 9B"]
        static let everyBuild = Set(ToolCallExposurePinTests.rows.map(\.switchGroup))

        static let all: [SwitchOff] = [
            .init(testDescription: "DARKBLOOM_TTFT_STREAM_TOOL_CALLS", switches: .init(toolCalls: false),
                  builds: everyBuild, forcedOnly: false),
            .init(testDescription: "DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS", switches: .init(forced: .none),
                  builds: everyBuild, forcedOnly: true),
            .init(testDescription: "Gemma 4's forced calls", switches: .init(forced: .init(gemma: false)),
                  builds: ["Gemma 4", "Gemma 4 text"], forcedOnly: true),
            .init(testDescription: "DARKBLOOM_TTFT_STREAM_FORCED_QWEN_TOOL_CALLS",
                  switches: .init(forced: .init(qwen: false)),
                  builds: ["Qwen 3.5 and 3.8 dense", "Qwen 3.5 and 3.6 MoE"], forcedOnly: true),
            .init(testDescription: "DARKBLOOM_TTFT_STREAM_FORCED_GPTOSS_TOOL_CALLS",
                  switches: .init(forced: .init(gptOSS: false)), builds: ["GPT-OSS"], forcedOnly: true),
            .init(testDescription: "the native families' forced calls", switches: .init(forced: .init(native: false)),
                  builds: native, forcedOnly: true),
            .init(testDescription: "GLM's forced calls", switches: .init(forced: .init(glm: false)),
                  builds: ["GLM-5.3-Flash"], forcedOnly: true),
            .init(testDescription: "DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS", switches: .init(native: false),
                  builds: native, forcedOnly: false),
            .init(testDescription: "DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS", switches: .init(glm: false),
                  builds: ["GLM-5.3-Flash"], forcedOnly: false),
        ]

        /// The default row with this switch's cells withheld.
        func expected(_ build: Build) -> String {
            guard builds.contains(build.switchGroup) else { return build.pinned }
            let marks = Array(build.pinned.filter { $0 != " " })
            let held = zip(marks, ToolCallExposurePinTests.cells).map { mark, cell -> Character in
                mark == "S" && (cell.choice.forced || !forcedOnly) ? "w" : mark
            }
            return String(held[..<3]) + " " + String(held[3...])
        }
    }

    @Test("each switch withholds exactly its own cells", arguments: SwitchOff.all)
    func switchOutcome(off: SwitchOff) {
        for build in Self.rows {
            #expect(Self.row { Self.scheduler(build, $0, clientStreams: $1, switches: off.switches) }
                == off.expected(build), "\(build.name)")
        }
    }

    @Test("Super's owner follows the native switch, and the forced one for its forced calls")
    func superOwnerSwitches() throws {
        #expect(try Self.row { try Self.superOwner($0, clientStreams: $1, native: false) } == "www www")
        #expect(try Self.row { try Self.superOwner($0, clientStreams: $1, forced: false) } == "Sww www")
    }

    /// A request may name another parser (`tool_call_parser`). The MiMo and
    /// Nemotron parsers stream for their own served builds alone; a parser
    /// without an incremental renderer streams nothing.
    @Test("a requested parser streams only where it renders fragments for that build")
    func requestedParsers() throws {
        func row(_ name: String, _ parser: String, switches: Switches = .init()) throws -> String {
            let build = try #require(Self.rows.first { $0.name == name })
            return Self.row { Self.scheduler(build, $0, clientStreams: $1, switches: switches, parser: parser) }
        }
        #expect(try row("Qwen 3.5 and 3.8 dense", "xml_function") == "www www")
        #expect(try row("Qwen 3.5 and 3.8 dense", "json") == "Sxx Sxx")
        #expect(try row("Gemma 4", "nemotron") == "wxx wxx")
        #expect(try row("Gemma 4", "mimo") == "wxx wxx")
        #expect(try row("Nemotron 3.5 Lightning", "json") == "wxx wxx")
        #expect(try row("Nemotron 3.5 Lightning", "xml_function") == "www www")
        #expect(try row("Bonsai 2 27B", "nemotron") == "wxx wxx")
        #expect(try row("Bonsai 2 27B", "xml_function") == "www www")
        #expect(try row("another Prism build", "nemotron") == "wxx wxx")
        #expect(try row("another Nemotron build", "json") == "Sxx Sxx")
        #expect(try row("Nemotron 3.5 Super on the scheduler", "json") == "Sxx Sxx")
        #expect(try row("GLM-5.3-Flash", "json") == "Sxx Sxx")
        #expect(try row("GLM-5.3-Flash", "nemotron") == "wxx wxx")
        #expect(try row("MiMo V2.6", "json") == "xxx xxx")
        #expect(try row("a type that is not served", "nemotron") == "wxx wxx")
        #expect(try row("a type that is not served", "qwen3_5") == "Sxx Sxx")
        // Other spellings, with the parser the type itself would have inferred.
        #expect(try row("gemma4, padded", "gemma") == "Sxx Sxx")
        #expect(try row("gpt_oss, padded", "harmony") == "SSS Sww")
        #expect(try row("gpt_oss, padded", "harmony", switches: .init(forced: .init(gptOSS: false))) == "Sww Sww")
        #expect(try row("qwen3_5, padded", "qwen3_5") == "SSS Sww")
        #expect(try row("qwen3_5_moe, padded", "qwen3_5", switches: .init(forced: .init(qwen: false))) == "Sww Sww")
        #expect(try row("qwen3_vl_moe, padded", "xml_function") == "www www")
        #expect(try row("prism_hadamard_qwen35, padded, Bonsai 2 27B", "qwen3_5") == "www www")
        #expect(try row("prism_hadamard_qwen35, padded, another build", "qwen3_5") == "Sww Sww")
        #expect(try row("nemotron_h, padded, Lightning", "nemotron") == "www www")
        #expect(try row("nemotron_h, padded, another build", "nemotron") == "wxx wxx")
        #expect(try row("mimo_v2, padded", "mimo") == "wxx wxx")
        #expect(try row("glm5_next, padded", "glm5") == "wxx wxx")
        #expect(try row("qwen4_exp, padded", "qwen3_5") == "www www")
        #expect(try row("diffusion_gemma, padded", "gemma") == "www www")
        #expect(try row("PRISM_HADAMARD_QWEN35, Bonsai 2 27B", "json") == "wxx wxx")
        #expect(try row("NEMOTRON_H, Lightning", "json") == "wxx wxx")
        #expect(try row("FLINT", "json") == "Sxx Sxx")
        #expect(try row("glm5_next_text", "json") == "Sxx Sxx")
        // No type: the id's own rule, once the request names the parser.
        #expect(try row("no type, a gemma-4 id", "gemma") == "SSS Sww")
        #expect(try row("no type, a gemma-4 id", "gemma", switches: .init(forced: .init(gemma: false))) == "Sww Sww")
        #expect(try row("no type, a qwen3.5 id", "xml_function") == "www www")
        #expect(try row("no type, a qwen3.5 id", "nemotron") == "www www")
        #expect(try row("no type, a qwen3.5 id", "qwen3_5") == "Sxx Sxx")
        #expect(try row("gpt_oss under a qwen3.5 id", "xml_function") == "www www")
    }

    /// GLM's JSON answer and Super's are withheld until they validate, so
    /// their calls are too; the other families' calls stream beside a format.
    @Test("a JSON response format withholds GLM's and Super's calls alone")
    func jsonResponseFormat() throws {
        let json = #""response_format":{"type":"json_object"}"#
        func row(_ name: String) throws -> String {
            let build = try #require(Self.rows.first { $0.name == name })
            return Self.row { Self.scheduler(build, $0, clientStreams: $1, extra: json) }
        }
        #expect(try row("GLM-5.3-Flash") == "www www")
        #expect(try row("glm5_next_text") == "www www")
        #expect(try row("Nemotron 3.5 Lightning") == "SSS www")
        #expect(try row("MiMo V2.6") == "SSS www")
        #expect(try row("Qwen 3.5 and 3.8 dense") == "SSS Sww")
        #expect(try Self.row { try Self.superOwner($0, clientStreams: $1, extra: json) } == "www www")
    }

    /// Without declared tools only MiMo keeps a parser (an undeclared call
    /// must fail validation, not leave as raw XML), and it takes the streamed
    /// route though no name is ever exposed.
    @Test("a request that declares no tools streams nothing, except MiMo's parser")
    func noToolsDeclared() throws {
        for build in Self.rows {
            let outcome = Self.scheduler(build, .auto, clientStreams: true, tools: nil)
            #expect(outcome == (build.modelType == "mimo_v2" ? "S" : "w"), "\(build.name)")
        }
        #expect(try Self.superOwner(.auto, clientStreams: true, tools: nil) == "w")
    }
}
