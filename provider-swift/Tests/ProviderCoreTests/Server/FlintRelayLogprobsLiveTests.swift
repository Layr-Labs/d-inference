import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// Opt-in real-weights check of OpenAI logprobs on the coordinator relay, the
/// only path that emits them (`EngineV2Logprobs.swift`). Sealed requests go
/// straight to the production handler on a paged Flint slot; no coordinator is
/// contacted, so this does not certify hosted routing or authorization.
@Suite("Flint relay logprobs", .serialized)
struct FlintRelayLogprobsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_FLINT_OPENROUTER_LIVE"] == "1"))
    func logprobsCoverVisibleOutputAndNeverWithheldReasoning() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["DARKBLOOM_FLINT_BACKEND"] == nil || env["DARKBLOOM_FLINT_BACKEND"] == "paged",
            "Flint live qualification requires paged attention")
        let root = try #require(env["DARKBLOOM_FLINT_CACHE"])
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(root)
        defer { ModelScanner.configureCacheDirectory(previous) }
        let priorCacheSettings = CacheStorage.settings
        let cacheRoot = URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("http-test-cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let volume = try CacheVolume.inspect(directory: cacheRoot.path)
        try CacheStorage.configure(.init(directory: volume.directory, volumeUUID: volume.uuid))
        defer { try? CacheStorage.configure(priorCacheSettings) }
        let id = "RecursiveSI/flint-int4"
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: id))
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id))
        try #require(model.modelType == "flint")
        let loop = try ProviderLoop(config: ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:1/unused",
            hardware: try HardwareDetector.detect(), models: [model], config: ProviderConfig(
                provider: ProviderSettings(name: "flint-relay-logprobs"),
                // Default backend settings, as a production provider ships them:
                // Flint must resolve paged attention and native precision on its own.
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1))),
            attestationSigner: nil)
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("flint-relay-logprobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        await loop.setDaemonStateFileForTesting(stateRoot.appendingPathComponent("state.json"))
        do {
            try await check(loop, id: id, receipt: env["DARKBLOOM_FLINT_RELAY_RECEIPTS"])
            _ = await loop.unloadModel(id)
        } catch {
            _ = await loop.unloadModel(id)
            throw error
        }
    }

    private func check(_ loop: ProviderLoop, id: String, receipt receiptPath: String?) async throws {
        try await loop.ensureModelLoaded(modelId: id, allowEviction: false)
        let bridge = try #require(await loop.slotBridgeForTesting(modelId: id))
        try #require(await bridge.kvBackendKind == .paged)
        try #require(bridge.kvQuantization == .native && bridge.kvCheckpointQuantization == .native)
        let receipt = receiptPath.map { URL(fileURLWithPath: $0) }
        if let receipt { try Data().write(to: receipt) }

        let prompt = "What is 2+2? Reply with the number only."
        for exclude in [false, true] {
            var body: [String: Any] = ["model": id, "stream": true, "max_tokens": 256, "temperature": 0,
                "logprobs": true, "top_logprobs": 3,
                "messages": [["role": "user", "content": prompt]]]
            if exclude { body["reasoning"] = ["exclude": true] }
            let run = try await relay(loop, body: body, name: exclude ? "exclude" : "visible")
            if let receipt, let handle = try? FileHandle(forWritingTo: receipt) {
                handle.seekToEndOfFile()
                let line = try JSONSerialization.data(withJSONObject: ["case": exclude ? "exclude" : "visible",
                    "content": run.content, "reasoning_chars": run.reasoning.count,
                    "logprob_tokens": run.entries.map { $0["token"] as? String ?? "" },
                    "errors": run.errors], options: [.sortedKeys])
                handle.write(line + Data("\n".utf8))
                try handle.close()
            }
            #expect(run.errors.isEmpty && run.completed, "\(exclude)")
            #expect(run.content.contains("4"), "\(exclude)")
            #expect(!run.entries.isEmpty, "\(exclude): logprobs requested on the relay")
            #expect(run.entries.allSatisfy { ($0["top_logprobs"] as? [[String: Any]])?.count == 3 }, "\(exclude)")
            #expect(run.entries.allSatisfy { ($0["logprob"] as? Double).map { $0 <= 0 } ?? false }, "\(exclude)")
            let joined = run.entries.compactMap { $0["token"] as? String }.joined()
            if exclude {
                #expect(run.reasoning.isEmpty)
                #expect(joined == run.content, "withheld reasoning never returns as logprob tokens")
            } else {
                #expect(joined.hasSuffix(run.content), "every visible token carries an entry")
            }
        }
    }

    private struct RelayRun {
        var content = ""
        var reasoning = ""
        var entries: [[String: Any]] = []
        var completed = false
        var errors: [String] = []
    }

    private func relay(_ loop: ProviderLoop, body: [String: Any], name: String) async throws -> RelayRun {
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes,
            plaintext: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        let recorder = LogprobsRelayRecorder()
        await loop.handleInferenceRequest(requestId: "flint-relay-logprobs-\(name)-\(UUID().uuidString)",
            ciphertext: encrypted, senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "test-tenant", firstContentDeadline: nil,
            send: SendHandle(recorder.record))
        let until = ContinuousClock.now + .seconds(600)
        while recorder.terminals == 0, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(20))
        }
        var run = RelayRun()
        for message in recorder.snapshot {
            switch message {
            case .inferenceChunk(_, _, let sealed?):
                let frame = String(decoding: try sender.decryptPayload(sealed), as: UTF8.self)
                for line in frame.split(separator: "\n") where line.hasPrefix("data: ") && line != "data: [DONE]" {
                    guard let object = try JSONSerialization.jsonObject(
                        with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                        let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
                    if let delta = choice["delta"] as? [String: Any] {
                        run.content += delta["content"] as? String ?? ""
                        run.reasoning += delta["reasoning_content"] as? String ?? ""
                    }
                    run.entries += (choice["logprobs"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                }
            case .inferenceComplete:
                run.completed = true
            case .inferenceError(_, let failure, _):
                run.errors.append(String(describing: failure))
            default:
                break
            }
        }
        return run
    }
}

private final class LogprobsRelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }
    var terminals: Int {
        snapshot.filter {
            switch $0 {
            case .inferenceComplete, .inferenceError: true
            default: false
            }
        }.count
    }
}
