import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionNamedToolBundleAnchor: NSObject {}

/// Fixed-count synthetic attribution through the actual HTTP responder. Uses
/// only the existing DEBUG observer, never production raw-text logging.
@Suite("DiffusionGemma named-tool serving attribution", .serialized)
struct DiffusionGemmaNamedToolDiagnosticLiveTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var rows = [String: [String]]()
        func append(id: String, text: String) { lock.withLock { rows[id, default: []].append(text) } }
        func reset() { lock.withLock { rows.removeAll() } }
        func snapshot() -> [String: [String]] { lock.withLock { rows } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_NAMED_TOOL_DIAGNOSTIC"] == "1"))
    func retainedNamedCasesRecordNativeAndHTTPBoundaries() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let selected = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        let inputs = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_RAW_CASES_DIR"]))
        let names = ["responses-named-off-plain", "responses-named-off-stream",
            "responses-named-on-plain", "responses-named-on-stream"]
        let fixtures = try names.map { name -> (String, Data, OpenAIChatCompletionRequest) in
            let fixture = try #require(try JSONSerialization.jsonObject(with:
                Data(contentsOf: inputs.appendingPathComponent(name + ".json"))) as? [String: Any])
            try #require(fixture["case"] as? String == name)
            let body = try #require(fixture["request"] as? [String: Any])
            try #require(body["model"] as? String == modelID && body["seed"] == nil)
            let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return (name, payload, try JSONDecoder().decode(OpenAIResponseRequest.self, from: payload).chatCompletionRequest)
        }
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        try #require(directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
            == selected.appendingPathComponent("config.json").resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionNamedToolBundleAnchor.self).bundleURL
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        try #require(model.isVision == true && model.templateRenderOK == true)
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token, engineV2KVBackend: "paged",
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        do {
            try await server.ensureModelLoaded(modelID)
            let capture = Capture()
            try await server.observeNamedToolNativeText(modelID) { id, text in capture.append(id: id, text: text) }
            try await server.makeApplication().test(.ahc()) { client in
                try #require(client.port != nil)
                // Every outcome is retained. Four rounds were declared before
                // execution; none is a seed replay of the earlier CLI failure.
                for round in 0..<4 {
                    for (name, payload, request) in fixtures {
                        capture.reset()
                        let response = try await client.execute(uri: "/v1/responses", method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                            body: ByteBuffer(data: payload))
                        let rawHTTP = String(buffer: response.body)
                        print("DIFFUSION_NAMED_TOOL_RESPONSE " + String(decoding:
                            try JSONSerialization.data(withJSONObject: ["round": round, "case": name,
                                "http": response.status.code, "rawHTTP": rawHTTP,
                                "nativeAtHTTPCompletion": capture.snapshot()], options: [.sortedKeys]), as: UTF8.self))
                        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                        while await server.debugActiveRequestCount(modelId: modelID) != 0 {
                            try #require(ContinuousClock.now < deadline, "Previous native request did not drain")
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        let captured = capture.snapshot()
                        try #require(captured.count <= 1, "Unexpected overlapping native requests")
                        let chunks = captured.values.first ?? []
                        let row: [String: Any] = ["round": round, "case": name,
                            "request": try JSONSerialization.jsonObject(with: payload),
                            "http": response.status.code, "rawHTTP": rawHTTP, "nativeChunks": chunks,
                            "chunkedParser": try Self.parse(chunks, request: request),
                            "joinedParser": try Self.parse([chunks.joined()], request: request),
                            "requestDrained": true, "originalFailureReplayed": false,
                            "scope": "new unseeded named-tool trajectories; collection is not semantic qualification",
                            "qualityQualification": false]
                        print("DIFFUSION_NAMED_TOOL " + String(decoding: try JSONSerialization.data(
                            withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                    }
                }
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
    }

    private static func parse(_ chunks: [String], request: OpenAIChatCompletionRequest) throws -> [String: Any] {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "diffusion_gemma")
        let handler = try ToolStreamPreparation.makeHandler(request: request,
            prepared: prepared, modelType: "diffusion_gemma")
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: prepared.requiresToolCall,
            nativePrefix: nil, nativeGemmaChannels: true,
            nativeGemmaReasoningEnabled: DiffusionGemmaReasoningControl.enabled(for: request, controls: .init()))
        var errors = [String]()
        do {
            for chunk in chunks { _ = try router.process(chunk) }
            _ = try router.finishText()
        } catch { errors.append(String(describing: error)) }
        let calls = handler?.finish() ?? []
        do { try ToolConstraintValidation.validate(calls, prepared: prepared) }
        catch { errors.append(String(describing: error)) }
        return ["calls": try JSONSerialization.jsonObject(with: JSONEncoder().encode(calls)), "errors": errors]
    }
}

private extension StandaloneServer {
    func observeNamedToolNativeText(_ modelID: String,
        observer: @escaping @Sendable (String, String) -> Void) async throws
    {
        let bridge = try #require(slots[modelID]?.bridge)
        await bridge.observeNamedToolNativeText(observer)
    }
}

private extension EngineV2Bridge {
    func observeNamedToolNativeText(_ observer: @escaping @Sendable (String, String) -> Void) {
        _testNativeTextObserver = observer
    }
}
