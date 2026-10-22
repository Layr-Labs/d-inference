// Copyright © 2026 Eigen Labs.

import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import MLX
import MLXLMCommon
import Testing
import UniformTypeIdentifiers
import zlib
@testable import ProviderCore

/// Gated full-checkpoint runs of the managed Super slot. Each loads about
/// 80 GB through the production loader; run only with exclusive GPU access,
/// `DARKBLOOM_SUPER_MANAGED_LIVE=1` and `NEMOTRON_SUPER_CHECKPOINT_DIR`.
extension NemotronSuperManagedSlotTests {
    /// The pinned checkpoint through the production loader, the real process
    /// budget and the encrypted coordinator path. Loads about 80 GB; run only
    /// with `DARKBLOOM_SUPER_MANAGED_LIVE=1` and `NEMOTRON_SUPER_CHECKPOINT_DIR`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil),
        .timeLimit(.minutes(10)))
    func pinnedCheckpointServesThroughTheManagedSlot() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.modelID))
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: try HardwareDetector.detect(), models: [model], config: .init(
                provider: .init(name: "super-managed-live"),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 1, mtpMode: .auto),
                coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let started = ContinuousClock.now
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false, revisionDirectory: directory)
        let loadSeconds = started.duration(to: .now)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let loaded = await owner.bridge.mtpStatusSnapshot()
        #expect(owner.speculates && loaded.active)
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let body = try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "stream": true,
            "temperature": 0, "max_tokens": 16, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": "What is 17 times 19? Reply with the number only."]]])
        let answer = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer)
        let usage = try #require(Self.usage(answer.terminal), "\(answer.terminal)")
        #expect(SuperSSE(answer.sse).content.contains("323"))
        let mtp = await owner.bridge.mtpStatusSnapshot()
        print("SUPER_MANAGED_LIVE load_s=\(loadSeconds) prompt=\(usage.promptTokens) "
            + "completion=\(usage.completionTokens) mtp_rounds=\(mtp.rounds) accepted=\(mtp.acceptedDraftTokens)")
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
        try await Self.awaitMemoryReturn(loop)
    }


    /// The pinned checkpoint through the production loader: PNG and JPEG
    /// requests on the speculating owner, then an image beside a text
    /// request. Loads about 80 GB; run only with `DARKBLOOM_SUPER_MANAGED_LIVE=1`
    /// and `NEMOTRON_SUPER_CHECKPOINT_DIR`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil),
        .timeLimit(.minutes(10)))
    func pinnedCheckpointServesImagesBesideSpeculativeText() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.modelID))
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: try HardwareDetector.detect(), models: [model], config: .init(
                provider: .init(name: "super-managed-live-images"),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 1, mtpMode: .auto),
                coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let started = ContinuousClock.now
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false, revisionDirectory: directory)
        let loadSeconds = started.duration(to: .now)
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let loaded = await owner.bridge.mtpStatusSnapshot()
        #expect(owner.speculates && loaded.active)
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let arithmetic = try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "stream": true,
            "temperature": 0, "max_tokens": 16, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": "What is 17 times 19? Reply with the number only."]]])
        var lines: [String] = []
        for (label, uri) in [("png", try Self.solidRedDataURI(.png)), ("jpeg", try Self.solidRedDataURI(.jpeg))] {
            let begin = ContinuousClock.now
            let answer = try await Self.send(try Self.colorQuestion(uri), to: loop, recorder: recorder, consumer: consumer)
            let content = SuperSSE(answer.sse).content
            #expect(content.lowercased().contains("red"), "\(label): \(content) \(answer.terminal)")
            let usage = Self.usage(answer.terminal)
            lines.append("\(label)_s=\(begin.duration(to: .now)) \(label)_prompt=\(usage.map { String($0.promptTokens) } ?? "none") "
                + "\(label)_answer=\(content.debugDescription)")
        }
        let beforeMixed = await owner.bridge.mtpStatusSnapshot()
        let concurrent = Box<(sse: String, terminal: OutboundMessage)>()
        let png = try Self.solidRedDataURI(.png)
        let text = try await Self.send(arithmetic, to: loop, recorder: recorder, consumer: consumer) { _ in
            if let body = try? Self.colorQuestion(png),
               let result = try? await Self.send(body, to: loop, recorder: recorder, consumer: consumer) {
                concurrent.set(result)
            }
        }
        let mixedImage = try #require(concurrent.value)
        #expect(SuperSSE(text.sse).content.contains("323"), "\(text.terminal)")
        #expect(SuperSSE(mixedImage.sse).content.lowercased().contains("red"), "\(mixedImage.terminal)")
        let mtp = await owner.bridge.mtpStatusSnapshot()
        print("SUPER_MANAGED_LIVE_IMAGES load_s=\(loadSeconds) " + lines.joined(separator: " ")
            + " mixed_text=\(SuperSSE(text.sse).content.debugDescription)"
            + " mixed_image=\(SuperSSE(mixedImage.sse).content.debugDescription)"
            + " mtp_rounds_mixed=\(mtp.rounds - beforeMixed.rounds) accepted=\(mtp.acceptedDraftTokens)")
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await loop.nemotronSuperRetainedWeightBytesForTesting() == 0)
        try await Self.awaitMemoryReturn(loop)
    }

    /// Fixed text prompts on the pinned checkpoint, greedy, written as JSON to
    /// `DARKBLOOM_SUPER_TEXT_IDENTITY_OUT` so two builds compare byte for byte.
    /// `DARKBLOOM_SUPER_LIVE_MTP=off` serves the plain owner.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
        && ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_TEXT_IDENTITY_OUT"] != nil),
        .timeLimit(.minutes(20)))
    func pinnedCheckpointTextIdentity() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(environment["DARKBLOOM_SUPER_TEXT_IDENTITY_OUT"]))
        let (loop, _) = try await Self.liveLoop(name: "super-text-identity")
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        var facts: [String] = []
        for item in 1...640 {
            let colors = ["red", "green", "blue", "amber", "violet", "teal", "ochre", "silver"]
            facts.append("Fact \(item): item \(item) is \(colors[(item * 7) % colors.count]) and weighs \(item % 97) kg.")
        }
        let document = facts.joined(separator: " ")
        let prompts: [(String, String, Bool, Int)] = [
            ("arith", "What is 17 times 19? Reply with the number only.", false, 16),
            ("short27", "Write one sentence about the Pacific Ocean for a children's book about the sea.", false, 60),
            ("explain", "Explain in three sentences why the sky is blue.", false, 96),
            ("code", "Write a Python function that returns the n-th Fibonacci number iteratively.", false, 128),
            ("french", "Décris Paris en deux phrases.", false, 64),
            ("chinese", "用两句话介绍长城。", false, 64),
            ("symbols", "Repeat exactly, then say done: ∮ ∂ ∇ 🤖 ⟨ψ|φ⟩ ¯\\_(ツ)_/¯ 𝔘𝔫𝔦𝔠𝔬𝔡𝔢", false, 48),
            ("reasoning", "A train leaves at 3pm at 60 mph. How far has it gone by 5:30pm?", true, 256),
            ("long8k", document + "\n\nWhat color is item 433, and how much does it weigh?", false, 32),
        ]
        var results: [String: [String: String]] = [:]
        for (name, content, thinking, maxTokens) in prompts {
            let body = try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "stream": true,
                "temperature": 0, "max_tokens": maxTokens, "chat_template_kwargs": ["enable_thinking": thinking],
                "messages": [["role": "user", "content": content]]])
            let begin = ContinuousClock.now
            let answer = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer, deadline: 600)
            let sse = SuperSSE(answer.sse), usage = Self.usage(answer.terminal)
            results[name] = ["content": sse.content, "reasoning": sse.reasoning,
                             "prompt": usage.map { String($0.promptTokens) } ?? "none",
                             "completion": usage.map { String($0.completionTokens) } ?? "none"]
            print("SUPER_TEXT_IDENTITY \(name) s=\(begin.duration(to: .now)) prompt=\(results[name]?["prompt"] ?? "")"
                + " completion=\(results[name]?["completion"] ?? "") content=\(String(sse.content.prefix(80)).debugDescription)")
            #expect(!sse.content.contains("<unk>") && usage != nil, "\(name)")
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: output)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print("SUPER_TEXT_IDENTITY sha256=\(digest)")
        #expect(await loop.unloadModel(Self.modelID))
        try await Self.awaitMemoryReturn(loop)
    }

    /// A fact retrieval question at the end of a long synthetic document
    /// (about 32,000 tokens by default; `DARKBLOOM_SUPER_NEEDLE_FACTS` sets the
    /// fact count) through the managed slot's served context.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
        && ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_NEEDLE"] == "1"),
        .timeLimit(.minutes(20)))
    func pinnedCheckpointFindsAFactInALongContext() async throws {
        let count = Int(ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_NEEDLE_FACTS"] ?? "") ?? 1_530
        let colors = ["red", "green", "blue", "amber", "violet", "teal", "ochre", "silver"]
        let facts = (1...count).map { item in
            "Fact \(item): item \(item) is \(colors[(item * 7) % colors.count]) and weighs \(item % 97) kg."
        }
        let target = count * 2 / 3
        let body = try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "stream": true,
            "temperature": 0, "max_tokens": 32, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": facts.joined(separator: " ")
                + "\n\nWhat color is item \(target), and how much does it weigh?"]]])
        let (loop, _) = try await Self.liveLoop(name: "super-needle")
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let begin = ContinuousClock.now
        let answer = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer, deadline: 900)
        let content = SuperSSE(answer.sse).content
        let usage = Self.usage(answer.terminal)
        print("SUPER_NEEDLE facts=\(count) prompt=\(usage.map { String($0.promptTokens) } ?? "none") "
            + "s=\(begin.duration(to: .now)) answer=\(content.debugDescription)")
        let color = colors[(target * 7) % colors.count]
        #expect(content.lowercased().contains(color) && content.contains("\(target % 97)"), "\(answer.terminal)")
        #expect(await loop.unloadModel(Self.modelID))
        try await Self.awaitMemoryReturn(loop)
    }

    /// Load, serve, unload, and load again: in the same loop and in a new
    /// loop of the same process, as the managed slot is reloaded in service.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil),
        .timeLimit(.minutes(10)))
    func pinnedCheckpointReloadsAfterUnload() async throws {
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let question = try Self.countBody(8)
        let (first, firstLoad) = try await Self.liveLoop(name: "super-reload")
        print("SUPER_RELOAD load1_s=\(firstLoad) " + (await Self.memoryLine(first)))
        for round in 1...2 {
            let answer = try await Self.send(question, to: first, recorder: recorder, consumer: consumer, deadline: 300)
            #expect(Self.usage(answer.terminal) != nil, "round \(round)")
            #expect(await first.unloadModel(Self.modelID))
            for wait in [0, 1, 3] {
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                print("SUPER_RELOAD round=\(round) after_unload+\(wait)s " + (await Self.memoryLine(first)))
            }
            if round == 1 {
                let started = ContinuousClock.now
                try await first.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                    revisionDirectory: URL(fileURLWithPath: try #require(
                        ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]), isDirectory: true))
                print("SUPER_RELOAD reload_same_loop_s=\(started.duration(to: .now))")
            }
        }
        let (second, secondLoad) = try await Self.liveLoop(name: "super-reload-new-loop")
        print("SUPER_RELOAD new_loop_load_s=\(secondLoad)")
        let answer = try await Self.send(question, to: second, recorder: recorder, consumer: consumer, deadline: 300)
        #expect(Self.usage(answer.terminal) != nil)
        #expect(await second.unloadModel(Self.modelID))
        try await Self.awaitMemoryReturn(second)
        print("SUPER_RELOAD final " + (await Self.memoryLine(second)))
    }

    struct TimedAnswer: Sendable {
        let content: String
        let reasoning: String
        let status: String
        let firstContentSeconds: Double?
        let totalSeconds: Double
        let promptTokens: UInt64?
    }

    /// One encrypted coordinator request; the time to its first content or
    /// reasoning token is measured from submission.
    static func sendTimed(_ body: Data, to loop: ProviderLoop, recorder: Recorder, consumer: NodeKeyPair,
                          deadline seconds: Int = 600) async throws -> TimedAnswer {
        let id = "super-live-\(UUID().uuidString)"
        let ciphertext = try consumer.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes,
                                              plaintext: body)
        let start = ContinuousClock.now
        await loop.handleInferenceRequest(requestId: id, ciphertext: ciphertext,
            senderPublicKey: consumer.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "tenant-live", send: SendHandle(recorder.record))
        var first: Duration?, seen = 0
        let deadline = start + .seconds(seconds)
        while recorder.terminal(id) == nil, ContinuousClock.now < deadline {
            let chunks = recorder.chunks(id)
            if first == nil, chunks.count > seen {
                for chunk in chunks[seen...] {
                    let frame = String(decoding: try consumer.decryptPayload(chunk), as: UTF8.self)
                    let parsed = SuperSSE(frame)
                    if !parsed.content.isEmpty || !parsed.reasoning.isEmpty { first = start.duration(to: .now); break }
                }
                seen = chunks.count
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let total = start.duration(to: .now)
        let terminal = try #require(recorder.terminal(id))
        let sse = SuperSSE(try recorder.chunks(id).map {
            String(decoding: try consumer.decryptPayload($0), as: UTF8.self) }.joined())
        let failure = failure(terminal)
        func toSeconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        return TimedAnswer(content: sse.content, reasoning: sse.reasoning,
            status: failure.map { "error \($0.statusCode)" } ?? "ok", firstContentSeconds: first.map(toSeconds),
            totalSeconds: toSeconds(total), promptTokens: usage(terminal).map(\.promptTokens))
    }

    static func imageQuestion(_ uri: String, _ question: String, maxTokens: Int = 48,
                              thinking: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true, "temperature": 0,
            "max_tokens": maxTokens, "chat_template_kwargs": ["enable_thinking": thinking],
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": uri]],
                                                      ["type": "text", "text": question]]]]])
    }

    /// A scene with known content: a red circle, a blue square and a word.
    static func sceneImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let unit = CGFloat(min(width, height)) / 4
        context.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        context.fillEllipse(in: CGRect(x: unit * 0.3, y: unit * 2.2, width: unit * 1.4, height: unit * 1.4))
        context.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: CGFloat(width) - unit * 1.9, y: unit * 2.2, width: unit * 1.4, height: unit * 1.4))
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String):
            CTFontCreateWithName("Helvetica-Bold" as CFString, unit * 0.6, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "HELLO", attributes: attributes))
        context.textPosition = CGPoint(x: unit * 0.4, y: unit * 0.6)
        CTLineDraw(line, context)
        return try #require(context.makeImage())
    }

    /// ImageIO encodings of one picture; `progressive` asks for a progressive JPEG.
    static func encode(_ image: CGImage, as type: UTType, progressive: Bool = false) throws -> String {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = progressive
            ? [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
               kCGImageDestinationLossyCompressionQuality: 0.9]
            : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return "data:image/\(type == .png ? "png" : "jpeg");base64," + (data as Data).base64EncodedString()
    }

    /// The live image matrix on the pinned checkpoint: sizes, formats, a
    /// content check, concurrency with speculating text and calibration, the
    /// second-image 429, history and reasoning. Writes a JSON summary to
    /// `DARKBLOOM_SUPER_IMAGE_MATRIX_OUT`; `DARKBLOOM_SUPER_LIVE_MTP=off` runs
    /// the plain owner.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_MANAGED_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
        && ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_IMAGE_MATRIX_OUT"] != nil),
        .timeLimit(.minutes(30)))
    func pinnedCheckpointImageMatrix() async throws {
        let output = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_IMAGE_MATRIX_OUT"]))
        let (loop, loadTime) = try await Self.liveLoop(name: "super-image-matrix")
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        var results: [[String: String]] = []
        func record(_ name: String, _ answer: TimedAnswer, expect keywords: [String] = []) {
            let lower = (answer.content + " " + answer.reasoning).lowercased()
            let missing = keywords.filter { !lower.contains($0) }
            results.append(["case": name, "status": answer.status,
                "ttft_s": answer.firstContentSeconds.map { String(format: "%.2f", $0) } ?? "none",
                "total_s": String(format: "%.2f", answer.totalSeconds),
                "prompt_tokens": answer.promptTokens.map(String.init) ?? "none",
                "content": String(answer.content.prefix(160)), "missing": missing.joined(separator: ",")])
            print("SUPER_IMAGE_MATRIX \(name) \(answer.status) ttft=\(answer.firstContentSeconds ?? -1) "
                + "prompt=\(answer.promptTokens.map(String.init) ?? "-") content=\(String(answer.content.prefix(100)).debugDescription)")
            #expect(answer.status == "ok" && !answer.content.contains("<unk>") && missing.isEmpty,
                    "\(name): \(answer.status) missing \(missing) \(answer.content.prefix(200))")
        }
        let describe = "Describe this image in one sentence: name the shapes, their colors and any written word."
        // Beside the post-load calibration probes, if they are still running.
        record("scene_1024_png_beside_calibration active=\(await owner.bridge.activeRequestCount())",
               try await Self.sendTimed(Self.imageQuestion(try Self.encode(Self.sceneImage(width: 1024, height: 1024), as: .png),
                                                            describe, maxTokens: 64), to: loop, recorder: recorder, consumer: consumer),
               expect: ["red", "blue", "hello"])
        // The inputs that overflowed the text-calibrated activation scales.
        let orange = Self.pngData(width: 256, height: 256, colorType: 2, bytesPerPixel: 3, extra: []) { _, _ in [255, 38, 0] }
        record("overflow_regression_255_38_0_png", try await Self.sendTimed(Self.colorQuestion(
            "data:image/png;base64," + orange.base64EncodedString()), to: loop, recorder: recorder, consumer: consumer),
            expect: ["red"])
        let gradient = Self.pngData(width: 256, height: 256, colorType: 2, bytesPerPixel: 3, extra: []) { x, y in
            [UInt8(x), UInt8(y), UInt8((x + y) / 2)] }
        record("overflow_regression_gradient_png", try await Self.sendTimed(Self.imageQuestion(
            "data:image/png;base64," + gradient.base64EncodedString(), "Describe this image briefly.", maxTokens: 32),
            to: loop, recorder: recorder, consumer: consumer))
        // Sizes and formats alone, with the content check.
        for (width, height) in [(256, 256), (1024, 1024), (2048, 1536), (2048, 1664)] {
            let scene = try Self.sceneImage(width: width, height: height)
            for (label, uri) in [("png", try Self.encode(scene, as: .png)), ("jpeg", try Self.encode(scene, as: .jpeg)),
                                 ("progressive_jpeg", try Self.encode(scene, as: .jpeg, progressive: true))] {
                record("scene_\(width)x\(height)_\(label)", try await Self.sendTimed(
                    Self.imageQuestion(uri, describe, maxTokens: 64), to: loop, recorder: recorder, consumer: consumer),
                    expect: ["red", "blue"])
            }
        }
        // PNG color types: RGBA, palette, gray.
        let rgba = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rgba.draw(try Self.sceneImage(width: 512, height: 512), in: CGRect(x: 0, y: 0, width: 512, height: 512))
        record("scene_512_rgba_png", try await Self.sendTimed(Self.imageQuestion(
            try Self.encode(try #require(rgba.makeImage()), as: .png), describe, maxTokens: 64),
            to: loop, recorder: recorder, consumer: consumer), expect: ["red", "blue"])
        let palette = Self.palettePNG(width: 256, height: 256) { x, _ in x < 128 ? 0 : 1 }
        record("halves_palette_png", try await Self.sendTimed(Self.imageQuestion(
            "data:image/png;base64," + palette.base64EncodedString(),
            "What two colors fill the left and right halves of this image?", maxTokens: 32),
            to: loop, recorder: recorder, consumer: consumer), expect: ["red", "green"])
        let gray = Self.grayPNG(width: 256, height: 256) { x, _ in UInt8(x) }
        record("gradient_gray_png", try await Self.sendTimed(Self.imageQuestion(
            "data:image/png;base64," + gray.base64EncodedString(), "Describe this image briefly.", maxTokens: 32),
            to: loop, recorder: recorder, consumer: consumer))
        // Beside 1...4 concurrent speculating text requests: text stays exact.
        let scene = try Self.encode(Self.sceneImage(width: 1024, height: 1024), as: .jpeg)
        let textBody = try Self.countBody(96)
        let reference = try await Self.sendTimed(textBody, to: loop, recorder: recorder, consumer: consumer)
        for width in 1...4 {
            let texts = Box<[TimedAnswer]>()
            let image = try await withThrowingTaskGroup(of: (Int, TimedAnswer).self) { group in
                for index in 0..<width {
                    group.addTask { (index, try await Self.sendTimed(textBody, to: loop, recorder: recorder, consumer: consumer)) }
                }
                try await Task.sleep(for: .milliseconds(300))
                let image = try await Self.sendTimed(Self.imageQuestion(scene, describe, maxTokens: 64),
                                                     to: loop, recorder: recorder, consumer: consumer)
                var collected: [TimedAnswer] = []
                for try await (_, answer) in group { collected.append(answer) }
                texts.set(collected)
                return image
            }
            record("scene_beside_\(width)_texts", image, expect: ["red", "blue"])
            let exact = (texts.value ?? []).allSatisfy { $0.content == reference.content }
            results.append(["case": "texts_beside_image_\(width)", "status": exact ? "exact" : "DIFFERENT"])
            #expect(exact, "text beside image \(width)")
        }
        // Two image requests at once: the second gets 429, the first answers.
        async let firstImage = Self.sendTimed(Self.imageQuestion(scene, describe, maxTokens: 64),
                                              to: loop, recorder: recorder, consumer: consumer)
        try await Task.sleep(for: .milliseconds(200))
        let secondImage = try await Self.sendTimed(Self.imageQuestion(scene, describe, maxTokens: 64),
                                                   to: loop, recorder: recorder, consumer: consumer)
        record("two_images_first", try await firstImage, expect: ["red", "blue"])
        results.append(["case": "two_images_second", "status": secondImage.status])
        #expect(secondImage.status == "error 429" || secondImage.status == "ok", "\(secondImage.status)")
        // Image, then text, then image.
        record("sequence_image_1", try await Self.sendTimed(Self.imageQuestion(scene, describe, maxTokens: 64),
            to: loop, recorder: recorder, consumer: consumer), expect: ["red", "blue"])
        let between = try await Self.sendTimed(textBody, to: loop, recorder: recorder, consumer: consumer)
        results.append(["case": "sequence_text", "status": between.content == reference.content ? "exact" : "DIFFERENT"])
        #expect(between.content == reference.content)
        record("sequence_image_2", try await Self.sendTimed(Self.imageQuestion(scene, describe, maxTokens: 64),
            to: loop, recorder: recorder, consumer: consumer), expect: ["red", "blue"])
        // An image in the history of a later turn.
        let history = try JSONSerialization.data(withJSONObject: ["model": Self.modelID, "stream": true,
            "temperature": 0, "max_tokens": 48, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": scene]],
                                                       ["type": "text", "text": "What color is the circle?"]]],
                         ["role": "assistant", "content": "The circle is red."],
                         ["role": "user", "content": "And what color is the square?"]]])
        record("history_follow_up", try await Self.sendTimed(history, to: loop, recorder: recorder, consumer: consumer),
               expect: ["blue"])
        // Reasoning on (bounded so a debug build stays inside the request deadline).
        let reasoning = try await Self.sendTimed(Self.imageQuestion(scene, "How many shapes are in this image? Answer with a number.",
            maxTokens: 384, thinking: true), to: loop, recorder: recorder, consumer: consumer)
        record("reasoning_on", reasoning)
        #expect(!reasoning.reasoning.isEmpty && !reasoning.reasoning.contains("<unk>"))
        let mtp = await owner.bridge.mtpStatusSnapshot()
        results.append(["case": "summary", "status": "load_s=\(loadTime) mtp_active=\(mtp.active) rounds=\(mtp.rounds)"])
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        #expect(await loop.unloadModel(Self.modelID))
        try await Self.awaitMemoryReturn(loop)
    }

    /// 8-bit palette PNG (red, green) with one IDAT.
    static func palettePNG(width: Int, height: Int, index: (Int, Int) -> UInt8) -> Data {
        pngData(width: width, height: height, colorType: 3, bytesPerPixel: 1,
                extra: [("PLTE", [255, 0, 0, 0, 160, 0])]) { x, y in [index(x, y)] }
    }

    /// 8-bit grayscale PNG with one IDAT.
    static func grayPNG(width: Int, height: Int, value: (Int, Int) -> UInt8) -> Data {
        pngData(width: width, height: height, colorType: 0, bytesPerPixel: 1, extra: []) { x, y in [value(x, y)] }
    }

    static func pngData(width: Int, height: Int, colorType: UInt8, bytesPerPixel: Int,
                        extra: [(String, [UInt8])], pixel: (Int, Int) -> [UInt8]) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(height * (1 + width * bytesPerPixel))
        for y in 0..<height {
            raw.append(0)
            for x in 0..<width { raw += pixel(x, y) }
        }
        var compressedLength = compressBound(uLong(raw.count))
        var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
        _ = compress(&compressed, &compressedLength, raw, uLong(raw.count))
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + payload
            let crc = UInt32(crc32(0, typed, uInt(typed.count)))
            return withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init) + typed
                + withUnsafeBytes(of: crc.bigEndian, Array.init)
        }
        let header = withUnsafeBytes(of: UInt32(width).bigEndian, Array.init)
            + withUnsafeBytes(of: UInt32(height).bigEndian, Array.init) + [8, colorType, 0, 0, 0]
        var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + chunk("IHDR", header)
        for (type, payload) in extra { bytes += chunk(type, payload) }
        bytes += chunk("IDAT", Array(compressed.prefix(Int(compressedLength)))) + chunk("IEND", [])
        return Data(bytes)
    }

    /// The next live test makes a new loop, which has no retirement window:
    /// wait (at most 5 s) until the OS has returned the unloaded pages.
    static func awaitMemoryReturn(_ loop: ProviderLoop) async throws {
        var previous = await loop.availableMemoryGb()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            let current = await loop.availableMemoryGb()
            if abs(current - previous) < 0.5 { return }
            previous = current
        }
    }

    /// MLX, OS and admission views of free memory, for reload diagnostics.
    static func memoryLine(_ loop: ProviderLoop) async -> String {
        let mlx = MLX.Memory.snapshot()
        let headroom = await loop.kvBudget.memoryHeadroomSnapshot()
        let gib = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
        return "mlx_active=\(gib(UInt64(mlx.activeMemory))) mlx_cache=\(gib(UInt64(mlx.cacheMemory))) "
            + "system_available=\(gib(headroom.systemAvailableBytes)) "
            + "unmaterialized=\(gib(headroom.unmaterializedCommittedBytes)) "
            + "available_for_load=" + String(format: "%.1f", await loop.availableMemoryGb())
    }

    /// A production-configured loop over the pinned checkpoint, loaded.
    static func liveLoop(name: String) async throws -> (ProviderLoop, Duration) {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]),
                            isDirectory: true)
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let mode: MTPMode = environment["DARKBLOOM_SUPER_LIVE_MTP"] == "off" ? .off : .auto
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: try HardwareDetector.detect(), models: [model], config: .init(
                provider: .init(name: name),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 1, mtpMode: mode),
                coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let started = ContinuousClock.now
        try await loop.ensureModelLoaded(modelId: modelID, allowEviction: false, revisionDirectory: directory)
        return (loop, started.duration(to: .now))
    }

    static func countBody(_ tokens: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true,
            "temperature": 0, "max_tokens": tokens, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": "Count from 1 to 200, separated by spaces."]]])
    }

    static func colorQuestion(_ image: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true,
            "temperature": 0, "max_tokens": 16, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": image]],
                ["type": "text", "text": "What color is this image? Answer with one word."]]]]])
    }

    /// A 256x256 solid red image, encoded by ImageIO.
    static func solidRedDataURI(_ type: UTType) throws -> String {
        let context = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let label = type == .png ? "png" : "jpeg"
        return "data:image/\(label);base64," + (data as Data).base64EncodedString()
    }
}
