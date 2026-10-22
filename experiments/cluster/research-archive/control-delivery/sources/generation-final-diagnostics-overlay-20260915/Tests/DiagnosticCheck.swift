import Foundation

@main enum DiagnosticCheck {
    static func main() throws {
        var accepted = [String](), rejected = [String]()
        func require(_ name: String, _ value: Bool) throws {
            guard value else { throw ProbeError("Diagnostic fixture failed: " + name) }
            accepted.append(name)
        }
        func reject(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { rejected.append(name); return }
            throw ProbeError("Diagnostic fixture accepted: " + name)
        }
        let gib = 1_073_741_824
        var calls = [Int]()
        let b = try QwenGenerationDiagnosticBudget.derive(rank: 1, vocabularySize: 248_320,
            activationDType: "bfloat16", requestReservedBytes: 3 * gib,
            bound: { calls.append($0); return $0 + 16_384 })
        try require("separate row and Float32 allocator calls", calls == [496_640, 993_280])
        try require("logical host copies", b.extraHostBytes == 1_489_920)
        try require("separate rounded native arrays", b.extraNativeBytes == 1_522_688)
        try require("base reserve preserved", b.originalRequestReservedBytes == 3 * gib)
        try require("actual free includes both host and native increments",
            try b.requiredActualFreeBytes(minimum: 6 * gib, headroom: 4 * gib) == 7 * gib + 3_012_608)
        try require("allocator excludes host copies but retains base/active/cache",
            try b.requiredAllocatorBytes(active: 101, cache: 203, headroom: 2 * gib) == 5 * gib + 1_522_992)
        calls = []
        let producer = try QwenGenerationDiagnosticBudget.derive(rank: 0, vocabularySize: 248_320,
            activationDType: "bfloat16", requestReservedBytes: gib,
            bound: { calls.append($0); return $0 })
        try require("producer has no final-row allocation", calls.isEmpty && producer.extraHostBytes == 0 && producer.extraNativeBytes == 0)
        try require("unchanged six GiB floor", try producer.requiredActualFreeBytes(minimum: 6 * gib, headroom: 4 * gib) == 6 * gib)
        let f32 = try QwenGenerationDiagnosticBudget.derive(rank: 1, vocabularySize: 7,
            activationDType: "float32", requestReservedBytes: 1, bound: { $0 })
        try require("F32 preserves two CPU copies", f32.logicalRowBytes == 28 && f32.float32RowBytes == 28 && f32.extraHostBytes == 56)
        for (name, rank, vocabulary, dtype, reserve) in [
            ("negative rank", -1, 10, "float16", 1), ("rank two", 2, 10, "float16", 1),
            ("empty vocabulary", 1, 0, "float16", 1), ("oversize vocabulary", 1, 262_145, "float16", 1),
            ("integer dtype", 1, 10, "uint32", 1), ("zero reserve", 1, 10, "float16", 0),
        ] {
            calls = []
            try reject(name) {
                _ = try QwenGenerationDiagnosticBudget.derive(rank: rank, vocabularySize: vocabulary,
                    activationDType: dtype, requestReservedBytes: reserve, bound: { calls.append($0); return $0 })
            }
            try require(name + " refuses before allocator", calls.isEmpty)
        }
        try reject("undersized allocator result") {
            _ = try QwenGenerationDiagnosticBudget.derive(rank: 1, vocabularySize: 7,
                activationDType: "float16", requestReservedBytes: 1, bound: { $0 - 1 })
        }
        try reject("native bound total overflow") {
            _ = try QwenGenerationDiagnosticBudget.derive(rank: 1, vocabularySize: 7,
                activationDType: "float16", requestReservedBytes: 1, bound: { _ in Int.max })
        }
        enum AllocatorFailure: Error { case original }
        do {
            _ = try QwenGenerationDiagnosticBudget.derive(rank: 1, vocabularySize: 7,
                activationDType: "float16", requestReservedBytes: 1, bound: { _ in throw AllocatorFailure.original })
            throw ProbeError("Expected allocator failure")
        } catch AllocatorFailure.original { accepted.append("original allocator failure preserved") }
        let large = try QwenGenerationDiagnosticBudget.derive(rank: 1, vocabularySize: 7,
            activationDType: "float16", requestReservedBytes: Int.max, bound: { $0 })
        try reject("free total overflow") { _ = try large.requiredActualFreeBytes(minimum: 1, headroom: 1) }
        try reject("allocator total overflow") { _ = try large.requiredAllocatorBytes(active: 1, cache: 0, headroom: 1) }
        try reject("negative active") { _ = try b.requiredAllocatorBytes(active: -1, cache: 0, headroom: 1) }
        try reject("negative cache") { _ = try b.requiredAllocatorBytes(active: 0, cache: -1, headroom: 1) }
        try reject("missing free floor") { _ = try b.requiredActualFreeBytes(minimum: 0, headroom: 1) }

        let profile = try QwenLayerStageGenerationProfile(identifier: "fabricated-9b-geometry",
            vocabularySize: 248_320, hiddenSize: 4096, activationDType: "bfloat16",
            maximumPromptTokens: 8192, maximumChunkTokens: 512, maximumOutputTokens: 128,
            maximumContextTokens: 8320)
        let request = try QwenLayerStageGenerationRequest(profile: profile,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            promptTokenIDs: Array(repeating: 1, count: 8192), chunkSize: 512, outputCount: 128, stopTokenIDs: [17])
        let history = Array(repeating: 2, count: 128)
        let complete = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: history,
            completedFrames: 143, committedTokens: 8319, reason: .length)
        try require("128 selections require 127 decodes and unconsumed final token",
            complete.finalFrame.sequence == 142 && complete.finalFrame.tokenOffset == 8318 && complete.finalFrame.tokenCount == 1
                && complete.committedTokens == 8319 && request.maximumTokens == 8320)
        try complete.requireCapture(rank: 0, frame: complete.finalFrame, frontier: 8319, tokenID: 2, hasLogits: false)
        try complete.requireCapture(rank: 1, frame: complete.finalFrame, frontier: 8319, tokenID: 2, hasLogits: true)
        accepted.append("both final rank capture shapes")
        let eos = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [17],
            completedFrames: 16, committedTokens: 8192, reason: .eos)
        try require("EOS after prefill has no decode", eos.finalFrame.finalPromptChunk && eos.selectedTokenCount == 1)
        let stopped = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [2, 3],
            completedFrames: 17, committedTokens: 8193, reason: .clientStop)
        try require("clean client stop retains actual frontier", stopped.committedTokens == 8193 && stopped.reason == .clientStop)
        try reject("empty output history") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [], completedFrames: 15, committedTokens: 8192, reason: .length)
        }
        try reject("early length") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [2], completedFrames: 16, committedTokens: 8192, reason: .length)
        }
        try reject("false EOS") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [2], completedFrames: 16, committedTokens: 8192, reason: .eos)
        }
        try reject("continued after EOS") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [17, 2], completedFrames: 17, committedTokens: 8193, reason: .clientStop)
        }
        try reject("out of vocabulary token") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [248_320], completedFrames: 16, committedTokens: 8192, reason: .clientStop)
        }
        try reject("attempted capacity is not committed frontier") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: history, completedFrames: 143, committedTokens: 8320, reason: .length)
        }
        try reject("wrong frame count") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: history, completedFrames: 144, committedTokens: 8319, reason: .length)
        }
        try reject("client stop masks output limit") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: history, completedFrames: 143, committedTokens: 8319, reason: .clientStop)
        }
        try reject("client stop masks EOS") {
            _ = try QwenGenerationDiagnosticCompletion(request: request, selectedTokenIDs: [17], completedFrames: 16, committedTokens: 8192, reason: .clientStop)
        }
        try reject("rank zero cannot return logits") {
            try complete.requireCapture(rank: 0, frame: complete.finalFrame, frontier: 8319, tokenID: 2, hasLogits: true)
        }
        try reject("rank one must return logits") {
            try complete.requireCapture(rank: 1, frame: complete.finalFrame, frontier: 8319, tokenID: 2, hasLogits: false)
        }
        try reject("unknown rank capture") {
            try complete.requireCapture(rank: 2, frame: complete.finalFrame, frontier: 8319, tokenID: 2, hasLogits: true)
        }
        try reject("stale frame capture") {
            try complete.requireCapture(rank: 1, frame: request.frame(sequence: 141), frontier: 8319, tokenID: 2, hasLogits: true)
        }
        try reject("stale frontier capture") {
            try complete.requireCapture(rank: 1, frame: complete.finalFrame, frontier: 8318, tokenID: 2, hasLogits: true)
        }
        try reject("changed selected scalar") {
            try complete.requireCapture(rank: 1, frame: complete.finalFrame, frontier: 8319, tokenID: 3, hasLogits: true)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "accepted": accepted, "rejected": rejected,
            "acceptedCount": accepted.count, "rejectedCount": rejected.count,
            "nativeExecution": false, "liveResourcePermissionCreated": false,
            "modelTensorPayloadRead": false, "bilateralRetirementExecuted": false,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
