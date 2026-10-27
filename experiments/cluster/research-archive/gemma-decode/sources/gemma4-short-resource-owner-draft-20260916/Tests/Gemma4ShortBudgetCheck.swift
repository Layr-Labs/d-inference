import Foundation

private struct ShortLedger: Decodable {
    struct Row: Decodable {
        struct Array: Decodable { let name: String; let bytes: Int }
        let selectedTensorCount: Int, selectedLogicalBytes: Int, largestHostTensorBytes: Int
        let persistentCastLogicalBytes: Int, stateLogicalBytes: Int, hostEvidenceBytes: Int
        let namedArrayCount: Int, namedLogicalBytes: Int
        let namedArrays: [Array]?
    }
    let targets: [String: Row]
    let candidateCuts: [String: [String: Row]]
}

func shortRequest(prompt: Int = 32, chunk: Int = 16, output: Int = 2, stops: Set<Int> = [],
                  dtype: String = "bfloat16", profileID: String = "registered_gemma4_26b_forward_validation_v1",
                  maximumPrompt: Int = 8192) throws -> QwenLayerStageGenerationRequest {
    let profile = try QwenLayerStageGenerationProfile(identifier: profileID,
        vocabularySize: 262144, hiddenSize: 2816, activationDType: dtype,
        maximumPromptTokens: maximumPrompt, maximumChunkTokens: 512,
        maximumOutputTokens: 128, maximumContextTokens: 8320)
    return try .init(profile: profile, requestID: UUID(uuidString: "4cccae6a-473d-4fdd-882e-40bd6a943cef")!,
        promptTokenIDs: Array(repeating: 123, count: prompt), chunkSize: chunk,
        outputCount: output, stopTokenIDs: stops)
}

func checkShortBudget(_ input: FixtureInputs, _ checks: FixtureChecks, ledgerURL: URL) throws {
    let expected = try JSONDecoder().decode(ShortLedger.self,
        from: BoundedProbeInput.data(ledgerURL, maximumBytes: 1_048_576))
    let plan = try Gemma4LayerStagePlan(artifact: input.artifact, cut: 10)
    let targets: [(String, Gemma4ForwardTarget)] = [("full-reference", .fullReference), ("stage-0", .stage(0)), ("stage-1", .stage(1))]
    let request = try shortRequest()
    for (name, target) in targets {
        guard let row = expected.targets[name], let arrays = row.namedArrays else { throw ProbeError("Missing independent logical row") }
        let budget = try Gemma4ShortResourceBudget.derive(plan: plan, target: target, request: request, bound: { $0 })
        try checks.require(name + " descriptor counts and logical source bytes",
            budget.selected.count == row.selectedTensorCount
            && budget.selected.reduce(0) { $0 + $1.source.layout.byteCount } == row.selectedLogicalBytes
            && budget.largestHostTensorBytes == row.largestHostTensorBytes)
        try checks.require(name + " all named logical arrays match independent metadata replay",
            budget.namedArrays.count == row.namedArrayCount
            && arrays.count == row.namedArrayCount
            && zip(budget.namedArrays, arrays).allSatisfy { $0.0.name == $0.1.name && $0.0.bytes == $0.1.bytes }
            && budget.namedNativeBytes == row.namedLogicalBytes
            && Set(budget.namedArrays.map(\.name)).count == budget.namedArrays.count)
        try checks.require(name + " persistent cast state and host evidence terms",
            budget.persistentCastLogicalBytes == row.persistentCastLogicalBytes
            && budget.stateLogicalBytes == row.stateLogicalBytes && budget.hostEvidenceBytes == row.hostEvidenceBytes)
        let layout = try LayerAttentionStateLayout(layers: budget.stateLayers, maximumTokens: 34, maximumChunkTokens: 16)
        try checks.require(name + " actual generic full-window geometry join",
            layout.exactKVCapacityBytes == budget.stateLogicalBytes
            && layout.conservativeKVCapacityBytes == budget.stateLogicalBytes
            && budget.namedArrays.filter { $0.name.hasSuffix(":oldKeys") || $0.name.hasSuffix(":oldValues") || $0.name.hasSuffix(":chunkKeys") || $0.name.hasSuffix(":chunkValues") }.reduce(0) { $0 + $1.bytes } == layout.windowTemporaryBytes)
        // Synthetic +17 is not a device result. It proves every allocation,
        // including small scalars/casts, is separately passed through the bound.
        var seen: [Int] = []
        let rounded = try Gemma4ShortResourceBudget.derive(plan: plan, target: target, request: request,
            bound: { seen.append($0); return $0 + 17 })
        try checks.require(name + " individual native-bound request conservation",
            seen.count == row.selectedTensorCount + row.namedArrayCount + 1
            && rounded.selectedBounds == budget.selectedBounds.map { $0 + 17 }
            && rounded.namedAllocationBounds == budget.namedAllocationBounds.map { $0 + 17 }
            && rounded.namedNativeBytes == row.namedLogicalBytes + row.namedArrayCount * 17
            && rounded.largestNativeCopyBytes == row.largestHostTensorBytes + 17)
        for dtype in ["float16", "bfloat16", "float32"] {
            let typed = try Gemma4ShortResourceBudget.derive(plan: plan, target: target,
                request: shortRequest(dtype: dtype), bound: { $0 })
            try checks.require(name + " F32 size ceiling independent of unobserved " + dtype,
                typed.stateLogicalBytes == budget.stateLogicalBytes && typed.namedNativeBytes == budget.namedNativeBytes)
        }
    }
    try Gemma4ShortResourceBudget.requireCandidateCut(plan)
    for cut in [8, 10, 12, 15] {
        let candidate = try Gemma4LayerStagePlan(artifact: input.artifact, cut: cut)
        for (name, target) in targets {
            guard let row = expected.candidateCuts[String(cut)]?[name] else { throw ProbeError("Missing candidate split replay") }
            let value = try Gemma4ShortResourceBudget.derive(plan: candidate, target: target, request: request, bound: { $0 })
            try checks.require("candidate cut\(cut) " + name + " exact metadata requirements",
                value.selected.count == row.selectedTensorCount
                && value.selected.reduce(0) { $0 + $1.source.layout.byteCount } == row.selectedLogicalBytes
                && value.namedArrays.count == row.namedArrayCount && value.namedNativeBytes == row.namedLogicalBytes
                && value.persistentCastLogicalBytes == row.persistentCastLogicalBytes
                && value.stateLogicalBytes == row.stateLogicalBytes && value.hostEvidenceBytes == row.hostEvidenceBytes)
        }
    }
    for cut in [1, 8, 12, 15, 29] {
        try checks.refuses("short scope rejects cut\(cut)") {
            try Gemma4ShortResourceBudget.requireCandidateCut(Gemma4LayerStagePlan(artifact: input.artifact, cut: cut))
        }
    }
    let changed = try [shortRequest(prompt: 31), shortRequest(prompt: 33), shortRequest(chunk: 8),
        shortRequest(output: 1), shortRequest(output: 3), shortRequest(stops: [1]),
        shortRequest(profileID: "registered_qwen9b"), shortRequest(maximumPrompt: 4096)]
    for (index, value) in changed.enumerated() {
        try checks.refuses("short scope rejects request substitution\(index)") {
            _ = try Gemma4ShortResourceBudget.derive(plan: plan, target: .fullReference, request: value, bound: { $0 })
        }
    }
    for rank in [-1, 2] {
        try checks.refuses("short scope rejects rank\(rank)") {
            _ = try Gemma4ShortResourceBudget.derive(plan: plan, target: .stage(rank), request: request, bound: { $0 })
        }
    }
    try checks.refuses("allocation bound below logical bytes") {
        _ = try Gemma4ShortResourceBudget.derive(plan: plan, target: .fullReference, request: request, bound: { $0 - 1 })
    }
    try checks.refuses("allocation sum overflow") {
        _ = try Gemma4ShortResourceBudget.derive(plan: plan, target: .fullReference, request: request, bound: { _ in Int.max })
    }
    try checks.refuses("allocator refusal is propagated") {
        _ = try Gemma4ShortResourceBudget.derive(plan: plan, target: .fullReference, request: request,
            bound: { _ in throw ProbeError("Synthetic maximum-buffer refusal") })
    }
}
