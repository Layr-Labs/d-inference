import CoreImage
import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
import MLXLMServer
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionMediaPrefixBundleAnchor: NSObject {}

@Suite("DiffusionGemma authenticated encrypted media prefix", .serialized)
struct DiffusionGemmaMediaPrefixLiveTests {
    enum MediaKind: String, Sendable { case image, video, interleaved }

    private struct Result: Equatable {
        let text: String
        let prompt: Int
        let completion: Int
        let cached: Int
        func sameOutput(as other: Self) -> Bool {
            text == other.text && prompt == other.prompt && completion == other.completion
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MEDIA_SSD_LIVE"] == "1"))
    func realImagesRepeatAppendAndChangedPixelsUseEncryptedNativeCheckpoints() async throws {
        try await exercise(.image)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_ORDERED_MEDIA_SSD_LIVE"] == "1"),
          arguments: [MediaKind.video, .interleaved])
    func orderedMediaRepeatAppendAndReversalUseNativeEncryptedState(_ kind: MediaKind) async throws {
        try await exercise(kind)
    }

    private func exercise(_ kind: MediaKind) async throws {
        let environment = ProcessInfo.processInfo.environment
        let memoryEnabled = PrefixCachePolicy.isMemoryEnabled(environment: environment)
        let ephemeral = SSDPrefixCacheFactory.forceEphemeralKey(environment: environment)
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let diskEnabled = PrefixCachePolicy.isEnabled(modelId: modelID, environment: environment)
        try #require(!memoryEnabled && ephemeral && diskEnabled)
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let selected = try #require(environment["DARKBLOOM_DIFFUSION_MODEL_DIR"])
        // The scanner's immutable HF snapshot contains per-file links, not a
        // directory symlink. Bind the selected config, then require the full
        // actual load aggregate below before qualifying any cache reuse.
        try #require(directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
            == URL(fileURLWithPath: selected).appendingPathComponent("config.json").resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        let resources = try #require(Bundle(for: DiffusionMediaPrefixBundleAnchor.self).resourceURL)
        let library = resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        let expected = try #require(hashFile(atPath: library.path))
        try #require(bindRuntimeMetallibForMLX(from: library) == expected && metallibHash() == expected)
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token, engineV2KVBackend: "paged",
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        let notes = (1...50).map { "Record \($0): Keep each request independent and ground the answer in the actual image." }.joined(separator: "\n")
        func imageURI(_ color: CIColor) throws -> String {
            let image = CIImage(color: color).cropped(to: .init(x: 0, y: 0, width: 64, height: 64))
            let png = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            return "data:image/png;base64," + png.base64EncodedString()
        }
        let blueImage = try imageURI(.blue), redImage = try imageURI(.red)
        var forwardVideo: String?, reverseVideo: String?
        if kind == .video {
            forwardVideo = dataURI(forMP4: try await makeSolidColorClip(colors: [
                (r: 0, g: 0, b: 255), (r: 255, g: 0, b: 0)], fps: 1, width: 64, height: 64))
            reverseVideo = dataURI(forMP4: try await makeSolidColorClip(colors: [
                (r: 255, g: 0, b: 0), (r: 0, g: 0, b: 255)], fps: 1, width: 64, height: 64))
        }
        func body(reversed: Bool = false, appended: Bool = false) throws -> Data {
            let instruction: String
            var content: [[String: Any]]
            switch kind {
            case .image:
                content = [["type": "image_url", "image_url": ["url": reversed ? redImage : blueImage]]]
                instruction = "Name the single dominant color of this image. Reply using only the color name."
            case .video:
                content = [["type": "video_url", "video_url": ["url": try #require(reversed ? reverseVideo : forwardVideo)]]]
                instruction = "Name the first color and then the second color shown in this video. Reply with only the two color names in order."
            case .interleaved:
                content = [["type": "image_url", "image_url": ["url": reversed ? redImage : blueImage]],
                    ["type": "text", "text": "This is the first image."],
                    ["type": "image_url", "image_url": ["url": reversed ? blueImage : redImage]]]
                instruction = "Name the colors of the first and second image, in order. Reply: first color, second color."
            }
            let text = notes + (appended ? "\nAdditional note: keep reporting actual image content." : "")
                + "\n" + instruction
            content.append(["type": "text", "text": text])
            return try JSONSerialization.data(withJSONObject: ["model": modelID,
                "messages": [["role": "user", "content": content]],
                "reasoning": ["enabled": false], "temperature": 1, "seed": 8132, "max_tokens": 64, "stream": false])
        }
        let blue = try body(), appended = try body(appended: true), red = try body(reversed: true)
        let traceRoot = environment["DARKBLOOM_DIFFUSION_MEDIA_TRACE_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let traceRoot {
            // Synthetic bodies only: no authentication headers or model arrays.
            // Preserve the exact media bytes for a matched ordinary-CLI probe.
            for (name, data) in [("cold", blue), ("appended", appended), ("changed", red)] {
                let file = traceRoot.appendingPathComponent("\(kind.rawValue)-\(name).json")
                try data.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        do {
            try await server.makeApplication().test(.ahc()) { client in
                try #require(client.port != nil)
                func request(_ data: Data, phase: String) async throws -> Result {
                    let started = ProcessInfo.processInfo.systemUptime
                    if traceRoot != nil { print("DIFFUSION_MEDIA_PHASE kind=\(kind.rawValue) phase=\(phase) event=start uptime=\(started)") }
                    // Keep the existing client's normal deadline unchanged.
                    let response: TestResponse
                    do {
                        response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                            body: ByteBuffer(data: data))
                    } catch {
                        if traceRoot != nil { print("DIFFUSION_MEDIA_PHASE kind=\(kind.rawValue) phase=\(phase) event=error elapsed=\(ProcessInfo.processInfo.systemUptime - started) type=\(String(reflecting: type(of: error)))") }
                        throw error
                    }
                    if traceRoot != nil { print("DIFFUSION_MEDIA_PHASE kind=\(kind.rawValue) phase=\(phase) event=response elapsed=\(ProcessInfo.processInfo.systemUptime - started) http=\(response.status.code)") }
                    try #require(response.status == .ok)
                    let json = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    let choices = try #require(json["choices"] as? [[String: Any]])
                    let message = try #require(choices.first?["message"] as? [String: Any])
                    let usage = try #require(json["usage"] as? [String: Any])
                    let details = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
                    #expect(choices.first?["finish_reason"] as? String == "stop")
                    return .init(text: message["content"] as? String ?? "", prompt: try #require(usage["prompt_tokens"] as? Int),
                        completion: try #require(usage["completion_tokens"] as? Int), cached: details["cached_tokens"] as? Int ?? 0)
                }
                func expectedColors(_ text: String, reversed: Bool) -> Bool {
                    let value = text.lowercased()
                    guard let first = value.range(of: reversed ? "red" : "blue") else { return false }
                    if kind == .image { return true }
                    guard let second = value.range(of: reversed ? "blue" : "red") else { return false }
                    return first.lowerBound < second.lowerBound
                }
                let cold = try await request(blue, phase: "cold")
                #expect(cold.prompt > 1024 && cold.cached == 0 && expectedColors(cold.text, reversed: false))
                // Observe the actual production processor/tower geometry, not
                // a guessed token count. Keep these diagnostic arrays in a
                // short-lived scope so they cannot retain a model at reload.
                func geometrySummary() async throws -> ([CBv2ImageSpan], [Int], [Int]) {
                    let parsed = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: blue)
                    let container = try #require(await server.diffusionPrefixTestContainer(modelID))
                    let prepared = try await EngineV2VisionPrefill.prepareDiffusion(container: container,
                        request: parsed, templateControls: .init(enableThinking: false))
                    #expect(prepared.promptTokens.count == cold.prompt)
                    let geometry = try DiffusionGemmaPrefillGeometry(promptCount: prepared.promptTokens.count,
                        chunkSize: EngineV2SlotFactory.diffusionPrefillChunkSize, spans: prepared.spans)
                    return (prepared.spans, geometry.boundaries,
                        geometry.boundaries.filter { geometry.permitsPersistentCapture(position: $0) })
                }
                let geometry = try await geometrySummary()
                print("DIFFUSION_MEDIA_GEOMETRY kind=\(kind.rawValue) spans=\(geometry.0.map { [$0.tokenOffset, $0.length] }) coldBoundaries=\(geometry.1) nativeStableBoundaries=\(geometry.2)")
                try #require(await server.diffusionPrefixTestPageOwner(modelID))
                let store = try #require(await server.diffusionPrefixTestStore(modelID))
                try #require(store.identity.modelAggregateHash
                    == "2ad9d4a10fe791e9e74a6475298c048e9da2d3df9e049eeb37a9d98055fcc2ce")
                await store.waitForWritesForTesting()
                try #require(store.usesEphemeralKey)
                #expect(store.stats().filesWritten > 0)
                let repeatBlue = try await request(blue, phase: "repeat")
                #expect(repeatBlue.sameOutput(as: cold) && repeatBlue.cached > 0)
                let extended = try await request(appended, phase: "appended")
                #expect(extended.cached > 0)
                let changed = try await request(red, phase: "changed")
                #expect(changed.prompt == cold.prompt && changed.cached == 0 && expectedColors(changed.text, reversed: true))
                await store.waitForWritesForTesting()
                let repeatRed = try await request(red, phase: "changed-repeat")
                #expect(repeatRed.sameOutput(as: changed) && repeatRed.cached > 0)
                #expect(store.stats().stageConsumptions >= 3 && store.stats().filesRead >= 6)
                await store.waitForWritesForTesting()
                try #require(await server.evictLRUIdleSlotForTesting())
                #expect(await server.debugOutstandingKVReservationBytes() == 0)
                // New ephemeral key on ordinary reload supplies an independent
                // cold appended reference, not an undocumented cache bypass.
                let coldAppend = try await request(appended, phase: "reload-appended")
                #expect(coldAppend.cached == 0 && coldAppend.sameOutput(as: extended))
                print("DIFFUSION_MEDIA_SSD kind=\(kind.rawValue) prompt=\(cold.prompt) repeatCached=\(repeatBlue.cached) appendCached=\(extended.cached) changedPixelsCached=\(changed.cached) changedRepeatCached=\(repeatRed.cached) reloadedAppendCached=\(coldAppend.cached) appendedEqualsCold=\(coldAppend.sameOutput(as: extended)) forwardMeaning=\(expectedColors(cold.text, reversed: false)) reversedMeaning=\(expectedColors(changed.text, reversed: true)) ramRetention=false pageBacked=true ephemeral=true")
            }
        } catch { await server.stopAndWait(); throw error }
        await server.stopAndWait()
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
    }
}
