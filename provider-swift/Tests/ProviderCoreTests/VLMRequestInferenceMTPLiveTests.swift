// Live, real-image end-to-end coverage for the VLM MTP speculative-decode
// path (`VLMRequestInference.stream` with `mtpDrafter:`).
//
// This is the final proof that multimodal Gemma 4 MTP works against a real
// image and a real ~14 GB qat-4bit VLM tower + its qat-4bit assistant
// drafter, through the exact `ModelContainer` / `container.perform` path
// ProviderLoop serves with. It runs TWO streams over the same request — a
// plain (mtpDrafter: nil) baseline and an MTP stream — and asserts the MTP
// output is coherent and broadly similar to the baseline.
//
// Gated by VLM_MTP_E2E=1 and requires both checkpoints in the local cache.
// Skips cleanly (recorded as a warning) when any precondition is unmet, so
// the default suite on a model-less / GPU-less runner stays green.
//
//   cd provider-swift
//   VLM_MTP_E2E=1 swift test --filter vlmMTPRealImageEndToEnd 2>&1 | tail -60
//
// NOTE on byte-identity: MTP and plain are NOT asserted byte-equal. The
// VLM tower verifies several drafted tokens per round in a single batched
// forward, and bf16 rounding makes a handful of near-tie logits resolve
// differently between the width-1 (plain) and width-N (verify) passes. That
// divergence is known and accepted; we assert a *loose* similarity (shared
// prefix or strong word overlap) instead of equality.

import CoreImage
import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

@testable import ProviderCore

private enum VLMMTPLiveFixtures {

    /// Opt-in env var for this (expensive, ~14 GB) live test.
    static let envVar = "VLM_MTP_E2E"

    static var enabled: Bool {
        ProcessInfo.processInfo.environment[envVar].map { !$0.isEmpty } ?? false
    }

    /// Multimodal Gemma 4 target (config declares `vision_config`).
    /// Overridable via VLM_MTP_TARGET_DIR for a differently-located snapshot.
    static var targetDir: String {
        ProcessInfo.processInfo.environment["VLM_MTP_TARGET_DIR"]
            ?? "/Users/gaj/.cache/huggingface/hub/models--mlx-community--gemma-4-26B-A4B-it-qat-4bit/snapshots/0e3cbab38ce568cf6e23543010d08d03b731910c"
    }

    /// Matching qat-4bit assistant drafter. Overridable via VLM_MTP_DRAFTER_DIR.
    static var drafterDir: String {
        ProcessInfo.processInfo.environment["VLM_MTP_DRAFTER_DIR"]
            ?? "/Users/gaj/.cache/huggingface/hub/models--mlx-community--gemma-4-26B-A4B-it-qat-assistant-4bit/snapshots/bb94eae1b70a80dac16cbf959bb4b7d56bd1fb8c"
    }

    /// First existing candidate image, or nil if none are present.
    static var testImage: URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["VLM_MTP_IMAGE"],
            "/Users/gaj/Downloads/eigen-labs-logo.png",
            "/Users/gaj/Downloads/exo-logo.png",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Outcome of consuming one `VLMRequestInference.stream`.
private struct StreamRun {
    var text: String
    var completionTokens: Int
    var promptTokens: Int
    var generationTime: TimeInterval
    /// Wall-clock seconds around stream consumption.
    var wallSeconds: Double

    /// Decode tokens/sec from the engine-reported generation time, falling
    /// back to wall clock when the engine didn't report a positive time.
    var tokensPerSecond: Double {
        if generationTime > 0 { return Double(completionTokens) / generationTime }
        if wallSeconds > 0 { return Double(completionTokens) / wallSeconds }
        return 0
    }
}

@Suite("VLM MTP real-image end-to-end (live)", .serialized)
struct VLMRequestInferenceMTPLiveTests {

    @Test(
        "VLM MTP describes a real image, coherent and similar to plain decode",
        .enabled(if: VLMMTPLiveFixtures.enabled)
    )
    func vlmMTPRealImageEndToEnd() async throws {
        // 0. Preconditions — skip cleanly (recorded warning) if unmet so the
        //    default suite stays green on a runner without these assets.
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            withKnownIssue("skipped: \(LiveFixtureSkip.missingMetallib)") {
                Issue.record("\(LiveFixtureSkip.missingMetallib)")
            }
            return
        }
        let targetURL = URL(fileURLWithPath: VLMMTPLiveFixtures.targetDir)
        let drafterURL = URL(fileURLWithPath: VLMMTPLiveFixtures.drafterDir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: targetURL.appendingPathComponent("config.json").path) else {
            withKnownIssue("skipped: VLM target not found at \(targetURL.path)") {
                Issue.record("VLM target not found at \(targetURL.path)")
            }
            return
        }
        guard fm.fileExists(atPath: drafterURL.appendingPathComponent("config.json").path) else {
            withKnownIssue("skipped: drafter not found at \(drafterURL.path)") {
                Issue.record("drafter not found at \(drafterURL.path)")
            }
            return
        }
        guard let imageURL = VLMMTPLiveFixtures.testImage else {
            withKnownIssue("skipped: no test image present") {
                Issue.record("no test image present (set VLM_MTP_IMAGE)")
            }
            return
        }

        // Cap MLX memory the same way ProviderLoop does; this is a big model.
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 24 * 1024 * 1024 * 1024)

        // 1. Load the real VLM ModelContainer via the SAME factory path
        //    ProviderLoop.loadModelContainer uses for a vision_config model.
        #expect(
            ProviderLoop.modelIsVLM(at: targetURL),
            "target must declare vision_config to exercise the VLM path")
        let container = try await VLMModelFactory.shared.loadContainer(
            from: targetURL,
            using: LocalTokenizerLoader()
        )

        // 2. Load the assistant drafter.
        let drafter = try await Gemma4AssistantDraftModel.load(from: drafterURL)

        // 3. Build the OpenAI request: one text part + one inline base64 image.
        let imageBytes = try Data(contentsOf: imageURL)
        let dataURI = "data:image/png;base64," + imageBytes.base64EncodedString()
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-vlm",
            messages: [
                .init(
                    role: .user,
                    content: .parts([
                        .text("Describe this image in one sentence."),
                        .imageURL(dataURI),
                    ]))
            ],
            temperature: 0,
            maxTokens: 64
        )
        #expect(VLMRequestInference.hasMedia(request), "request must be detected as multimodal")

        // 4. Run TWO streams: plain baseline, then MTP.
        let plain = try await runStream(
            container: container, request: request, drafter: nil)
        let mtp = try await runStream(
            container: container, request: request, drafter: drafter)

        // 5. Coherence + similarity assertions.
        let plainTrim = plain.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mtpTrim = mtp.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let letterCount = mtpTrim.filter { $0.isLetter }.count
        let coherent = mtpTrim.count > 0 && letterCount >= 10 && !isDegenerate(mtpTrim)

        let prefix = commonPrefixLength(plainTrim, mtpTrim)
        let jaccard = wordJaccard(plainTrim, mtpTrim)
        // "Similar" = a meaningful shared prefix OR strong word overlap. bf16
        // near-ties in the width-N verify pass can flip a token mid-stream, so
        // we deliberately do NOT require byte-identity.
        let similar = prefix >= 8 || jaccard >= 0.4

        let speedup = plain.tokensPerSecond > 0
            ? mtp.tokensPerSecond / plain.tokensPerSecond : 0

        // 6. Full diagnostic dump for the manual record.
        print("================ VLM MTP real-image E2E ================")
        print("image: \(imageURL.lastPathComponent)  (\(imageBytes.count) bytes)")
        print("target: \(VLMMTPLiveFixtures.targetDir)")
        print("drafter: \(VLMMTPLiveFixtures.drafterDir)")
        print("----------------- PLAIN (baseline) --------------------")
        print(plainTrim)
        print("[plain] completion_tokens=\(plain.completionTokens) "
            + "prompt_tokens=\(plain.promptTokens) "
            + String(format: "tok/s=%.2f wall=%.2fs gen=%.2fs",
                plain.tokensPerSecond, plain.wallSeconds, plain.generationTime))
        print("----------------- MTP ---------------------------------")
        print(mtpTrim)
        print("[mtp]   completion_tokens=\(mtp.completionTokens) "
            + "prompt_tokens=\(mtp.promptTokens) "
            + String(format: "tok/s=%.2f wall=%.2fs gen=%.2fs",
                mtp.tokensPerSecond, mtp.wallSeconds, mtp.generationTime))
        print("----------------- SIMILARITY --------------------------")
        print(String(
            format: "common_prefix_chars=%d  word_jaccard=%.3f  speedup=%.2fx  coherent=%@  similar=%@",
            prefix, jaccard, speedup,
            coherent ? "yes" : "no", similar ? "yes" : "no"))
        print("=======================================================")

        // Assertions.
        let coherentMsg = "MTP output must be coherent (>=10 letters, not degenerate): \(mtpTrim.prefix(120))"
        let similarMsg = "MTP must be loosely similar to plain (prefix=\(prefix) jaccard=\(jaccard)). "
            + "plain=<\(plainTrim.prefix(120))> mtp=<\(mtpTrim.prefix(120))>"
        #expect(mtpTrim.count > 0, "MTP output must be non-empty")
        #expect(coherent, "\(coherentMsg)")
        #expect(plainTrim.count > 0, "plain baseline must be non-empty")
        #expect(similar, "\(similarMsg)")
    }

    // MARK: - Stream consumption

    /// Consume one `VLMRequestInference.stream`, timing the wall clock around
    /// the iteration and collecting content + the final `.info`.
    private func runStream(
        container: ModelContainer,
        request: OpenAIChatCompletionRequest,
        drafter: Gemma4AssistantDraftModel?
    ) async throws -> StreamRun {
        let stream = VLMRequestInference.stream(
            container: container,
            request: request,
            defaultMaxTokens: 64,
            mtpDrafter: drafter,
            mtpBlockSize: 3
        )
        var text = ""
        var completionTokens = 0
        var promptTokens = 0
        var generationTime: TimeInterval = 0
        let start = Date()
        for try await event in stream {
            switch event {
            case .content(let chunk):
                text += chunk
            case .info(let info):
                completionTokens = info.completionTokens
                promptTokens = info.promptTokens
                generationTime = info.generationTime
            case .toolCall:
                continue
            }
        }
        let wall = Date().timeIntervalSince(start)
        return StreamRun(
            text: text,
            completionTokens: completionTokens,
            promptTokens: promptTokens,
            generationTime: generationTime,
            wallSeconds: wall)
    }

    // MARK: - Similarity / coherence helpers

    /// Length (in characters) of the common leading prefix of two strings.
    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            count += 1
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return count
    }

    /// Jaccard similarity over lowercased word sets.
    private func wordJaccard(_ a: String, _ b: String) -> Double {
        let wa = Set(words(a))
        let wb = Set(words(b))
        if wa.isEmpty && wb.isEmpty { return 1 }
        let inter = wa.intersection(wb).count
        let union = wa.union(wb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Detect obviously-broken output: a single token/word repeated many
    /// times with almost no lexical variety.
    private func isDegenerate(_ s: String) -> Bool {
        let ws = words(s)
        guard ws.count >= 6 else { return false }
        let unique = Set(ws).count
        return Double(unique) / Double(ws.count) < 0.2
    }
}
