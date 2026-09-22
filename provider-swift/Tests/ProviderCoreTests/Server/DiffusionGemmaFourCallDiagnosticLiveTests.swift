import CryptoKit
import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionFourCallBundleAnchor: NSObject {}

private enum FourCallFixtureError: Error { case unsupported }

private func fourCallFixtureName(_ requested: String?) throws -> String {
  let selected = requested ?? "responses-four-on-stream"
  guard ["responses-four-on-stream", "responses-four-on-plain"].contains(selected) else {
    throw FourCallFixtureError.unsupported
  }
  return selected
}

@Suite("DiffusionGemma four-call fixture selection")
struct DiffusionGemmaFourCallFixtureTests {
  @Test func onlyExplicitPlainAndStreamFixturesAreAccepted() throws {
    #expect(try fourCallFixtureName(nil) == "responses-four-on-stream")
    #expect(try fourCallFixtureName("responses-four-on-stream") == "responses-four-on-stream")
    #expect(try fourCallFixtureName("responses-four-on-plain") == "responses-four-on-plain")
    for name in [
      "", "../responses-four-on-plain", "responses-named-on-plain", "responses-four-off-plain",
    ] {
      #expect(throws: FourCallFixtureError.self) { try fourCallFixtureName(name) }
    }
  }
}

/// Bounded synthetic attribution. The existing DEBUG observer is absent from
/// release builds; no sampling control or production logging is added.
@Suite("DiffusionGemma four-call serving attribution", .serialized)
struct DiffusionGemmaFourCallDiagnosticLiveTests {
  private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [String: [String]]()
    func append(id: String, text: String) { lock.withLock { rows[id, default: []].append(text) } }
    func reset() { lock.withLock { rows.removeAll() } }
    func snapshot() -> [String: [String]] { lock.withLock { rows } }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_FOUR_CALL_DIAGNOSTIC"] == "1"))
  func retainedRequestRecordsNativeChunksAndActualHTTPOutcomes() async throws {
    let environment = ProcessInfo.processInfo.environment
    let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
    let selected = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
    let fixtureName = try fourCallFixtureName(environment["DARKBLOOM_DIFFUSION_FOUR_CALL_CASE"])
    let input = URL(fileURLWithPath: try #require(environment["DARKBLOOM_DIFFUSION_RAW_CASES_DIR"]))
      .appendingPathComponent(fixtureName + ".json")
    let inputBytes = try Data(contentsOf: input)
    let inputHash = SHA256.hash(data: inputBytes).map { String(format: "%02x", $0) }.joined()
    let fixture = try #require(try JSONSerialization.jsonObject(with: inputBytes) as? [String: Any])
    try #require(fixture["case"] as? String == fixtureName)
    let body = try #require(fixture["request"] as? [String: Any])
    try #require(body["model"] as? String == modelID && body["seed"] == nil)
    try #require(body["stream"] as? Bool == (fixtureName == "responses-four-on-stream"))
    let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let request = try JSONDecoder().decode(OpenAIResponseRequest.self, from: payload)
      .chatCompletionRequest
    let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
    try #require(
      directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
        == selected.appendingPathComponent("config.json").resolvingSymlinksInPath())
    try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
    _ = Bundle(for: DiffusionFourCallBundleAnchor.self).bundleURL
    let model = try #require(
      ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
    try #require(model.isVision == true && model.templateRenderOK == true)
    let token = UUID().uuidString + UUID().uuidString
    let server = StandaloneServer(
      config: .init(
        authToken: token, engineV2KVBackend: "paged",
        coordinatorURL: "http://127.0.0.1:1"), models: [model])
    await server.activateDiffusionRouterHarness()
    do {
      try await server.ensureModelLoaded(modelID)
      let capture = Capture()
      try await server.observeFourCallNativeText(modelID) { id, text in
        capture.append(id: id, text: text)
      }
      try await server.makeApplication().test(.ahc()) { client in
        try #require(client.port != nil)
        // Fixed trial count, not retries until success. Each result is
        // retained; an earlier unseeded trajectory is not recreated.
        for trial in 0..<16 {
          capture.reset()
          let start = ContinuousClock.now
          let response = try await client.execute(
            uri: "/v1/responses", method: .post,
            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
            body: ByteBuffer(data: payload))
          let rawHTTP = String(buffer: response.body)
          // Preserve the outcome even if the subsequent drain fails.
          print(
            "DIFFUSION_FOUR_CALL_RESPONSE "
              + String(
                decoding:
                  try JSONSerialization.data(
                    withJSONObject: [
                      "trial": trial,
                      "fixtureCase": fixtureName, "fixtureReceiptSHA256": inputHash,
                      "http": response.status.code, "rawHTTP": rawHTTP,
                      "nativeAtHTTPCompletion": capture.snapshot(),
                    ], options: [.sortedKeys]), as: UTF8.self))
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          while await server.debugActiveRequestCount(modelId: modelID) != 0 {
            try #require(ContinuousClock.now < deadline, "Previous native request did not drain")
            try await Task.sleep(for: .milliseconds(5))
          }
          let captured = capture.snapshot()
          try #require(captured.count <= 1, "Unexpected overlapping native requests")
          let chunks = captured.values.first ?? []
          let chunked = try Self.parse(chunks, request: request)
          let joined = try Self.parse([chunks.joined()], request: request)
          let row: [String: Any] = [
            "trial": trial,
            "fixtureCase": fixtureName, "fixtureReceiptSHA256": inputHash,
            "request": try JSONSerialization.jsonObject(with: payload),
            "http": response.status.code, "rawHTTP": rawHTTP,
            "nativeChunks": chunks, "chunkedParser": chunked, "joinedParser": joined,
            "elapsed": String(describing: start.duration(to: .now)),
            "requestDrained": true, "originalFailureReplayed": false,
            "scope": "new unseeded diagnostic trajectories through actual authenticated HTTP",
            "qualityQualification": false,
          ]
          print(
            "DIFFUSION_FOUR_CALL "
              + String(
                decoding: try JSONSerialization.data(
                  withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
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

  private static func parse(_ chunks: [String], request: OpenAIChatCompletionRequest) throws
    -> [String: Any]
  {
    let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "diffusion_gemma")
    let handler = try ToolStreamPreparation.makeHandler(
      request: request,
      prepared: prepared, modelType: "diffusion_gemma")
    var router = NativeToolStreamRouter(
      handler: handler, requiresToolCall: prepared.requiresToolCall,
      nativePrefix: nil, nativeGemmaChannels: true)
    var errors = [String]()
    do {
      for chunk in chunks { _ = try router.process(chunk) }
      _ = try router.finishText()
    } catch { errors.append(String(describing: error)) }
    let calls = handler?.finish() ?? []
    do { try ToolConstraintValidation.validate(calls, prepared: prepared) } catch {
      errors.append(String(describing: error))
    }
    return [
      "calls": try JSONSerialization.jsonObject(with: JSONEncoder().encode(calls)),
      "errors": errors,
    ]
  }
}

extension StandaloneServer {
  fileprivate func observeFourCallNativeText(
    _ modelID: String,
    observer: @escaping @Sendable (String, String) -> Void
  ) async throws {
    let bridge = try #require(slots[modelID]?.bridge)
    await bridge.observeFourCallNativeText(observer)
  }
}

extension EngineV2Bridge {
  fileprivate func observeFourCallNativeText(
    _ observer: @escaping @Sendable (String, String) -> Void
  ) {
    _testNativeTextObserver = observer
  }
}
