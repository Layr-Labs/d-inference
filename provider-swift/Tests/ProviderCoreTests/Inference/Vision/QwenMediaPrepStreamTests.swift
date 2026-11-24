// Copyright © 2026 Eigen Labs.
//
// Qwen 3.5-family media preparation runs on its own GPU stream
// (`EngineV2VisionPrefill.onMediaPrepStream`; on by default). These
// tests drive the serving entry point, `EngineV2VisionPrefill.prepare`, over a
// tiny synthetic Qwen3.5 wrapper whose processor records the stream it runs on,
// so the real tower, span carving and M-RoPE positions run with no model weights.

import Foundation
import MLX
@testable import MLXLMCommon
import MLXLMServer
import MLXNN
import MLXVLM
import Testing

@testable import ProviderCore

// A real, round-trip-verified 1x1 PNG (red pixel), as in MediaIngestTests. The
// recording processor below replaces the processed media, so the image only
// has to decode.
private let mediaPrepStreamPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

private let mediaPrepStreamConfigJSON = Data(
    """
    {
      "model_type": "qwen3_5_moe",
      "mtp_num_hidden_layers": 1,
      "text_config": {
        "model_type": "qwen3_5_moe",
        "hidden_size": 64,
        "num_hidden_layers": 2,
        "intermediate_size": 128,
        "num_attention_heads": 1,
        "num_key_value_heads": 1,
        "head_dim": 64,
        "linear_num_value_heads": 1,
        "linear_num_key_heads": 1,
        "linear_key_head_dim": 64,
        "linear_value_head_dim": 64,
        "linear_conv_kernel_dim": 4,
        "vocab_size": 64,
        "full_attention_interval": 1,
        "num_experts": 0,
        "num_experts_per_tok": 0,
        "moe_intermediate_size": 64,
        "shared_expert_intermediate_size": 64,
        "mtp_num_hidden_layers": 1
      },
      "vision_config": {
        "model_type": "qwen3_5_moe",
        "depth": 1,
        "hidden_size": 64,
        "intermediate_size": 128,
        "out_hidden_size": 64,
        "num_heads": 1,
        "patch_size": 16,
        "spatial_merge_size": 1,
        "temporal_patch_size": 1,
        "num_position_embeddings": 8
      }
    }
    """.utf8)

private func mediaPrepStreamConfiguration() throws -> MLXVLM.Qwen35Configuration {
    try JSONDecoder().decode(MLXVLM.Qwen35Configuration.self, from: mediaPrepStreamConfigJSON)
}

/// Returns one 2 x 2 image (four soft tokens with merge 1) for a tiny Qwen3.5
/// wrapper, and records whether each call ran on the process default GPU stream.
private final class StreamRecordingQwenProcessor: UserInputProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _onProcessDefaultStream: [Bool] = []
    private var _streams: [String] = []
    private let seam: Qwen35VisionSeamConfiguration
    private let patchWidth: Int

    static let grid = THW(1, 2, 2)

    init(wrapper: MLXVLM.Qwen35) {
        seam = wrapper.visionSeamConfiguration
        let vision = wrapper.config.visionConfiguration
        patchWidth = vision.patchSize * vision.patchSize * vision.temporalPatchSize
            * vision.inChannels
    }

    var onProcessDefaultStream: [Bool] { lock.withLock { _onProcessDefaultStream } }
    /// The GPU stream each call ran on (`Stream(gpu, index)`).
    var streams: [String] { lock.withLock { _streams } }

    var promptTokens: [Int] {
        [5, seam.visionStartTokenId]
            + Array(repeating: seam.imagePlaceholderTokenId, count: Self.grid.product)
            + [seam.visionEndTokenId, 6]
    }

    func prepare(input: UserInput) async throws -> LMInput {
        let onDefault = MLXProcessStreams.isOnDefaultGPUStream
        let stream = MLX.Stream.gpu.description
        lock.withLock {
            _onProcessDefaultStream.append(onDefault)
            _streams.append(stream)
        }
        let rows = Self.grid.product
        let pixels = MLXArray(
            (0 ..< rows * patchWidth).map { Float(($0 * 37) % 101) / 101 - 0.5 },
            [rows, patchWidth])
        let tokens = promptTokens
        return LMInput(
            text: .init(tokens: MLXArray(tokens.map { Int32($0) }).reshaped(1, tokens.count)),
            image: .init(pixels: pixels, frames: [Self.grid]))
    }
}

private struct MediaPrepStreamFixture {
    let container: ModelContainer
    let processor: StreamRecordingQwenProcessor
    let request: OpenAIChatCompletionRequest

    init() throws {
        let configuration = try mediaPrepStreamConfiguration()
        let wrapper = MLXVLM.Qwen35MoE(configuration)
        // Materialize the toy weights here, so no lazy initializer graph on
        // the default stream enters the first preparation.
        eval(wrapper)
        processor = StreamRecordingQwenProcessor(wrapper: wrapper)
        container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "tiny/qwen-media-prep-stream"),
                model: wrapper, processor: processor, tokenizer: StubBridgeTokenizer()))
        let imagePart: [String: Any] = [
            "type": "image_url", "image_url": ["url": mediaPrepStreamPNGDataURI],
        ]
        let message: [String: Any] = [
            "role": "user",
            "content": [["type": "text", "text": "describe"], imagePart] as [Any],
        ]
        let object: [String: Any] = [
            "model": "tiny/qwen-media-prep-stream", "max_tokens": 4, "messages": [message],
        ]
        let body = try JSONSerialization.data(withJSONObject: object)
        request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "qwen3_5_moe")
    }

    func prepare(ownStream: Bool?) async throws -> EngineV2VisionPrefill.PreparedSubmission {
        try await EngineV2VisionPrefill.prepare(
            container: container, request: request, ownMediaPrepStream: ownStream)
    }

    /// The serving call: no override, the switch read from `environment`.
    func prepare(environment: [String: String]) async throws -> EngineV2VisionPrefill.PreparedSubmission {
        try await EngineV2VisionPrefill.prepare(
            container: container, request: request, environment: environment)
    }
}

private func qwen3VLExclusionFixture() throws -> MLXVLM.Qwen3VL {
    let data = Data(
        """
        {
          "model_type": "qwen3_vl_moe",
          "text_config": {
            "model_type": "qwen3_vl_moe_text",
            "hidden_size": 8,
            "intermediate_size": 16,
            "num_hidden_layers": 1,
            "num_attention_heads": 1,
            "num_key_value_heads": 1,
            "head_dim": 8,
            "max_position_embeddings": 64,
            "vocab_size": 32,
            "num_experts": 4,
            "num_experts_per_tok": 2,
            "decoder_sparse_step": 1,
            "mlp_only_layers": [],
            "moe_intermediate_size": 4,
            "norm_topk_prob": true
          },
          "vision_config": {
            "model_type": "qwen3_vl_moe",
            "depth": 1,
            "hidden_size": 8,
            "hidden_act": "gelu_pytorch_tanh",
            "intermediate_size": 16,
            "out_hidden_size": 8,
            "num_heads": 1,
            "patch_size": 2,
            "spatial_merge_size": 1,
            "temporal_patch_size": 1,
            "num_position_embeddings": 8,
            "deepstack_visual_indexes": []
          }
        }
        """.utf8)
    return MLXVLM.Qwen3VL(
        try JSONDecoder().decode(MLXVLM.Qwen3VLConfiguration.self, from: data))
}

/// A module the way a deferred vision tower is built: a random-initialized
/// placeholder whose checkpoint replaces its parameters on first use.
private final class DeferredTowerFixture: Module {
    @ModuleInfo(key: "vision_tower") var tower: Linear

    override init() {
        _tower.wrappedValue = Linear(4, 4)
        super.init()
    }
}

private func bytes(_ array: MLXArray) -> Data {
    array.asData(access: .copy).data
}

@Suite("Qwen media preparation stream", .serialized)
struct QwenMediaPrepStreamTests {
    init() {
        // The tiny tower evaluates MLX arrays on the GPU.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("a Qwen 3.5-family wrapper prepares media off the process default GPU stream")
    func qwenPreparesOnItsOwnStream() async throws {
        let fixture = try MediaPrepStreamFixture()
        let prepared = try await fixture.prepare(ownStream: true)

        #expect(fixture.processor.onProcessDefaultStream == [false])
        #expect(prepared.promptTokens == fixture.processor.promptTokens)
        #expect(prepared.spans.count == 1 && prepared.spans.first?.length == 4)
        #expect(prepared.embeddings.count == 1 && prepared.embeddings.first?.shape == [1, 4, 64])
        #expect(prepared.attention == .causal && prepared.positionState != nil)
        // Everything the engine receives is materialized before the stream is
        // released.
        #expect(prepared.mlxArrays.count == 2)
    }

    @Test("with no override and the variable unset, preparation takes its own stream")
    func defaultIsOwnStream() async throws {
        try #require(
            ProcessInfo.processInfo.environment[EngineV2VisionPrefill.mediaPrepStreamEnvironmentKey] == nil,
            "the test process must not set the variable")
        let fixture = try MediaPrepStreamFixture()
        _ = try await fixture.prepare(ownStream: nil)

        #expect(fixture.processor.onProcessDefaultStream == [false])
    }

    @Test("the pooled stream is checked out again and its submissions stay usable on the default stream")
    func submissionOutlivesItsStream() async throws {
        let fixture = try MediaPrepStreamFixture()
        let first = try await fixture.prepare(ownStream: true)
        let second = try await fixture.prepare(ownStream: true)
        let shared = try await fixture.prepare(ownStream: false)

        #expect(fixture.processor.onProcessDefaultStream == [false, false, true])
        let streams = fixture.processor.streams
        // The second preparation reused the stream the first one released.
        #expect(streams.count == 3 && streams[0] == streams[1] && streams[0] != streams[2])
        #expect(MLXProcessStreams.isOnDefaultGPUStream)
        // Only now are the own-stream submissions read, on the default stream,
        // against the shared-stream reference.
        for submission in [first, second] {
            #expect(submission.mlxArrays.count == shared.mlxArrays.count)
            for (a, b) in zip(submission.mlxArrays, shared.mlxArrays) {
                #expect(bytes(a * 2) == bytes(b * 2))
                #expect(bytes(a) == bytes(b))
            }
        }
    }

    @Test("a deferred component's first-use load inside the scope leaves the global key untouched")
    func deferredLoadKeepsTheGlobalKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-prep-deferred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tower.safetensors")
        let weight = MLXArray((0 ..< 16).map { Float($0) / 16 }, [4, 4])
        let bias = MLXArray([Float](repeating: 0.5, count: 4))
        try MLX.save(arrays: ["vision_tower.weight": weight, "vision_tower.bias": bias], url: file)
        struct CheckpointFailure: Error {}
        // A load that fails after the placeholder was built stays pending and
        // leaves the global key alone too.
        let failing = OnDemandComponent(.vision) { DeferredTowerFixture() }
        failing.setSource(
            AnyOnDemandComponent.Source(
                urls: [file], namespaces: ["vision_tower"], perLayerQuantization: nil,
                prepare: { _ in throw CheckpointFailure() }))
        let component = OnDemandComponent(.vision) { DeferredTowerFixture() }
        component.setSource(
            AnyOnDemandComponent.Source(
                urls: [file], namespaces: ["vision_tower"], perLayerQuantization: nil, prepare: { $0 }))
        #expect(failing.isPending && component.isPending)

        let beforeFailure = MLXRandom.globalState.innerState()[0]
        await #expect(throws: CheckpointFailure.self) {
            try await EngineV2VisionPrefill.onMediaPrepStream(true) {
                _ = try failing.load()
                return EngineV2VisionPrefill.PreparedSubmission(
                    promptTokens: [], spans: [], embeddings: [], mediaKind: .image)
            }
        }
        #expect(failing.isPending && !failing.isLoaded)
        #expect(MLXRandom.globalState.innerState()[0] === beforeFailure)

        let before = MLXRandom.globalState.innerState()[0]
        _ = try await EngineV2VisionPrefill.onMediaPrepStream(true) {
            let loaded = try component.load()
            #expect(bytes(loaded.tower.weight) == bytes(weight))
            return EngineV2VisionPrefill.PreparedSubmission(
                promptTokens: [], spans: [], embeddings: [], mediaKind: .image)
        }
        let after = MLXRandom.globalState.innerState()[0]

        #expect(component.isLoaded)
        #expect(before === after)
        // A later implicit draw from the global key runs on the default stream.
        let draw = MLXRandom.normal([2])
        eval(draw)
        #expect(draw.shape == [2])
    }

    @Test("random draws inside the scope leave the process-global key untouched")
    func scopeKeepsTheGlobalRandomKey() async throws {
        let before = MLXRandom.globalState.innerState()[0]
        let empty = try await EngineV2VisionPrefill.onMediaPrepStream(true) {
            // What a deferred tower's first-use construction does: draw
            // placeholder weights with no explicit key.
            eval(MLXRandom.normal([4]))
            return EngineV2VisionPrefill.PreparedSubmission(
                promptTokens: [], spans: [], embeddings: [], mediaKind: .image)
        }
        let after = MLXRandom.globalState.innerState()[0]

        #expect(empty.mlxArrays.isEmpty)
        #expect(before === after)
    }

    @Test("the environment switch reaches prepare: on by default, off for an off word")
    func environmentSwitchReachesPrepare() async throws {
        let key = EngineV2VisionPrefill.mediaPrepStreamEnvironmentKey
        let fixture = try MediaPrepStreamFixture()
        _ = try await fixture.prepare(environment: [key: "1"])
        _ = try await fixture.prepare(environment: [:])
        _ = try await fixture.prepare(environment: [key: "0"])

        #expect(fixture.processor.onProcessDefaultStream == [false, false, true])
    }

    @Test("the switch keeps media preparation on the process default GPU stream")
    func switchOffKeepsTheDefaultStream() async throws {
        let fixture = try MediaPrepStreamFixture()
        _ = try await fixture.prepare(ownStream: false)

        #expect(fixture.processor.onProcessDefaultStream == [true])
    }

    @Test("embeddings, spans and positions are byte-identical on either stream")
    func ownStreamIsByteIdentical() async throws {
        let fixture = try MediaPrepStreamFixture()
        let own = try await fixture.prepare(ownStream: true)
        let shared = try await fixture.prepare(ownStream: false)

        #expect(fixture.processor.onProcessDefaultStream == [false, true])
        #expect(own.promptTokens == shared.promptTokens)
        #expect(own.spans == shared.spans)
        #expect(own.embeddings.count == 1 && shared.embeddings.count == 1)
        for (a, b) in zip(own.embeddings, shared.embeddings) {
            #expect(a.shape == b.shape && a.dtype == b.dtype)
            #expect(bytes(a) == bytes(b))
        }
        let ownPositions = try #require(own.positionState)
        let sharedPositions = try #require(shared.positionState)
        #expect(bytes(ownPositions.promptPositionIds) == bytes(sharedPositions.promptPositionIds))
        #expect(ownPositions.decodeDeltas == sharedPositions.decodeDeltas)
    }

    @Test("a failed preparation's error propagates and its stream scope ends")
    func failedPreparationPropagates() async throws {
        struct PreparationFailure: Error {}
        await #expect(throws: PreparationFailure.self) {
            try await EngineV2VisionPrefill.onMediaPrepStream(true) {
                #expect(!MLXProcessStreams.isOnDefaultGPUStream)
                throw PreparationFailure()
            }
        }
        #expect(MLXProcessStreams.isOnDefaultGPUStream)
    }

    @Test("only Qwen 3.5-family wrappers use their own stream")
    func onlyQwen35Wrappers() throws {
        let configuration = try mediaPrepStreamConfiguration()
        #expect(EngineV2VisionPrefill.preparesOnOwnStream(MLXVLM.Qwen35(configuration)))
        #expect(EngineV2VisionPrefill.preparesOnOwnStream(MLXVLM.Qwen35MoE(configuration)))
        let qwen3VL = try qwen3VLExclusionFixture()
        #expect(!EngineV2VisionPrefill.preparesOnOwnStream(qwen3VL))
        #expect(!EngineV2VisionPrefill.preparesOnOwnStream(NSObject()))
    }

    @Test("DARKBLOOM_TTFT_MEDIA_PREP_STREAM is on by default and off only for the off words")
    func environmentSwitch() {
        let key = EngineV2VisionPrefill.mediaPrepStreamEnvironmentKey
        #expect(key == "DARKBLOOM_TTFT_MEDIA_PREP_STREAM")
        #expect(EngineV2VisionPrefill.mediaPrepStreamEnabled(environment: [:]))
        for on in ["1", "true", "on", "yes", "", "2"] {
            #expect(EngineV2VisionPrefill.mediaPrepStreamEnabled(environment: [key: on]), "\(on)")
        }
        for off in ["0", "false", "no", "off", " OFF "] {
            #expect(!EngineV2VisionPrefill.mediaPrepStreamEnabled(environment: [key: off]), "\(off)")
        }
    }

    @Test("the switch reaches the launchd provider job, not the watchdog")
    func switchIsForwardedToTheProviderJob() {
        let key = EngineV2VisionPrefill.mediaPrepStreamEnvironmentKey
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(!WatchdogAgent.passthroughEnvKeys.contains(key))
        let out = LaunchAgent.passthroughEnvironment(from: [key: "0", "UNRELATED_SECRET": "excluded"])
        #expect(out == [key: "0"])
        #expect(!EngineV2VisionPrefill.mediaPrepStreamEnabled(environment: out))
    }

    /// The mechanism, timed: work queued on the default GPU stream (as a busy
    /// engine's steps are) delays shared-stream media preparation by its whole
    /// length and own-stream preparation by little. GPU timing, so opt-in.
    @Test(
        "own-stream media preparation does not wait for work queued on the default stream",
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] == "1",
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to time media preparation against a busy default stream")
    )
    func ownStreamDoesNotQueueBehindTheDefaultStream() async throws {
        let fixture = try MediaPrepStreamFixture()
        _ = try await fixture.prepare(ownStream: true)
        _ = try await fixture.prepare(ownStream: false)

        let side = 2048
        let matrix = MLXRandom.normal([side, side]) * (1 / Float(side).squareRoot())
        eval(matrix)
        func load(_ count: Int) -> MLXArray {
            var x = matrix
            for _ in 0 ..< count { x = matmul(x, matrix) }
            return x
        }
        let clock = ContinuousClock()
        let calibrationStart = clock.now
        eval(load(32))
        let perStep = (clock.now - calibrationStart) / 32
        let steps = max(64, Int((Duration.seconds(2) / perStep).rounded()))

        for ownStream in [true, false, true, false] {
            let queued = load(steps)
            let loadStart = clock.now
            asyncEval(queued)
            let prepStart = clock.now
            _ = try await fixture.prepare(ownStream: ownStream)
            let prep = clock.now - prepStart
            eval(queued)
            let remaining = clock.now - prepStart
            print(
                "media prep on \(ownStream ? "its own" : "the default") stream: \(prep); "
                    + "default-stream work left at its start: \(remaining) "
                    + "(queued in \(prepStart - loadStart), \(steps) steps)")
            if ownStream {
                #expect(prep < remaining / 4)
            } else {
                #expect(prep > remaining / 2)
            }
        }
    }
}
