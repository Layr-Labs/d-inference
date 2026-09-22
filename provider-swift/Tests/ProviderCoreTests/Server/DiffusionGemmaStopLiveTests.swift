import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionStopBundleAnchor: NSObject {}

@Suite("DiffusionGemma actual HTTP stop accounting", .serialized)
struct DiffusionGemmaStopLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_STOP_HTTP_LIVE"] == "1"))
    func requestedStopClipsVisibleTextAndCompletionUsage() async throws {
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"])
        let selected = URL(fileURLWithPath: path)
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        try #require(directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
            == selected.appendingPathComponent("config.json").resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionStopBundleAnchor.self).bundleURL
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token, engineV2KVBackend: "paged",
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        @Sendable func body(stop: Bool, stream: Bool) throws -> Data {
            var value: [String: Any] = ["model": modelID,
                "messages": [["role": "user", "content": "What is 17 times 19? Reply with the number only."]],
                "temperature": 1, "seed": 341, "max_tokens": 64,
                "reasoning": ["enabled": false], "stream": stream]
            if stop { value["stop"] = ["2"] }
            if stream { value["stream_options"] = ["include_usage": true] }
            return try JSONSerialization.data(withJSONObject: value)
        }
        do {
            try await server.ensureModelLoaded(modelID)
            try await server.makeApplication().test(.ahc()) { client in
                try #require(client.port != nil)
                let unauthorized = try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json"], body: ByteBuffer(data: body(stop: false, stream: false)))
                #expect(unauthorized.status == .unauthorized)
                var baselineCompletion = 0, stoppedCompletion = 0
                for stop in [false, true] {
                    let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: body(stop: stop, stream: false)))
                    try #require(response.status == .ok)
                    let json = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    let choice = try #require((json["choices"] as? [[String: Any]])?.first)
                    let message = try #require(choice["message"] as? [String: Any])
                    let content = try #require(message["content"] as? String)
                    let completion = try #require((json["usage"] as? [String: Any])?["completion_tokens"] as? Int)
                    #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == (stop ? "3" : "323"))
                    #expect(choice["finish_reason"] as? String == "stop")
                    if stop { stoppedCompletion = completion } else { baselineCompletion = completion }
                }
                #expect(stoppedCompletion > 0 && stoppedCompletion < baselineCompletion,
                    "The stop must not charge the later native EOS or trailing canvas")
                let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                    body: ByteBuffer(data: body(stop: true, stream: true)))
                try #require(response.status == .ok)
                let wire = String(decoding: response.body.readableBytesView, as: UTF8.self)
                var content = "", finishes = [String](), usage = [Int](), done = 0
                for line in wire.components(separatedBy: .newlines) where line.hasPrefix("data: ") {
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { done += 1; continue }
                    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                    if let count = (json["usage"] as? [String: Any])?["completion_tokens"] as? Int { usage.append(count) }
                    for choice in json["choices"] as? [[String: Any]] ?? [] {
                        content += (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
                        if let finish = choice["finish_reason"] as? String { finishes.append(finish) }
                    }
                }
                #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
                #expect(finishes == ["stop"] && usage == [stoppedCompletion] && done == 1)
                print("DIFFUSION_HTTP_STOP baselineCompletion=\(baselineCompletion) stoppedCompletion=\(stoppedCompletion) streamEquality=true terminalCount=\(done)")
            }
        } catch { await server.stopAndWait(); throw error }
        await server.stopAndWait()
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
    }
}
