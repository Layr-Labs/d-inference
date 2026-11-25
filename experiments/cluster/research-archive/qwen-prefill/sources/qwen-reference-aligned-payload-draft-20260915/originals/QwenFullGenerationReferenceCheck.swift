import Foundation

struct QwenFullGenerationReferenceCheckRecord: Encodable {
    let kind = "qwen_full_generation_reference_entry_check"
    let accepted: Int
    let rejected: Int
    let cpuOnly = true
    let actualAllocatorOrLiveResourceAdmissionPerformed = false
    let modelOrNativeForwardExecuted = false
}

func checkQwenFullGenerationReferenceEntry() throws -> QwenFullGenerationReferenceCheckRecord {
    guard let path = ProcessInfo.processInfo.environment["DARKBLOOM_RETAINED_PROFILE_FIXTURE"] else {
        throw ProbeError("Full-reference CPU check requires the retained profile fixture")
    }
    let data = try BoundedProbeInput.data(URL(fileURLWithPath: path), maximumBytes: 1_048_576)
    guard sha256(data) == "1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25",
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError("Full-reference CPU fixture differs")
    }
    var accepted = 0, rejected = 0
    for (key, model) in [("nine", QwenRegisteredDenseModel.qwen35NineB), ("twentySeven", .qwen38TwentySevenB)] {
        guard let row = root[key] as? [String: Any] else { throw ProbeError("Missing registered reference fixture") }
        let result = try checkQwenRegisteredGenerationReferenceModel(row, model: model)
        accepted += result.accepted; rejected += result.rejected
    }
    return .init(accepted: accepted, rejected: rejected)
}

private func checkQwenRegisteredGenerationReferenceModel(_ row: [String: Any],
    model: QwenRegisteredDenseModel) throws -> QwenFullGenerationReferenceCheckRecord {
    let definition = try QwenResidentModelDefinition(model: model)
    let specification = definition.specification
    guard let configText = row["configuration"] as? String, let config = Data(base64Encoded: configText),
          let manifestText = row["manifest"] as? String, let manifest = Data(base64Encoded: manifestText),
          let tensorsValue = row["canonicalTensors"] else { throw ProbeError("Full-reference model fixture differs") }
    let tensors = try JSONDecoder().decode([QwenDenseCanonicalTensor].self,
        from: JSONSerialization.data(withJSONObject: tensorsValue))
    let prompt = try JSONEncoder().encode(Array(repeating: 17, count: 8192))
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
    let arguments = ["--mode", QwenFullGenerationReferenceCLI.mode,
        "--model-dir", "/invented/model", "--tokens-file", "/invented/prompt.json", "--tokens-sha256", sha256(prompt),
        "--request-id", id.uuidString.lowercased(), "--stage-cut", "4", "--output-count", "128",
        "--stop-token-ids", "[]", "--timeout-seconds", "300",
        "--registered-dense-profile", model.rawValue, "--prompt-count", "8192", "--chunk-size", "512"]
    var accepted = 0, rejected = 0
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError("Full reference fixture: \(message)") }
        accepted += 1
    }
    func refuse(_ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Full reference fixture accepted an invalid case")
    }
    func changed(_ flag: String, _ value: String) -> [String] {
        var copy = arguments; copy[copy.firstIndex(of: flag)! + 1] = value; return copy
    }
    func read(_ url: URL, _: Int) throws -> Data {
        switch url.path {
        case "/invented/model/config.json": return config
        case "/invented/model/manifest.json": return manifest
        case "/invented/prompt.json": return prompt
        default: throw ProbeError("Unexpected fabricated read")
        }
    }
    let environment = QwenLongPrefillArithmeticEnvironment.requiredValues
    let cli = try QwenFullGenerationReferenceCLI(arguments: arguments)
    var reads = 0
    let input = try cli.preflight(environment: environment, read: { url, count in reads += 1; return try read(url, count) })
    try require(reads == 3 && input.admission.request.requestID == id
        && input.admission.request.forwardCount == 143 && input.admission.request.maximumTokens == 8320
        && input.admission.request.finalCommittedTokens == 8319, "exact O128 request/read geometry")
    for cut in definition.supportedCuts {
        let value = try QwenFullGenerationReferenceCLI(arguments: changed("--stage-cut", String(cut)))
        let admitted = try value.preflight(environment: environment, read: read)
        try require(admitted.admission.source.plan.stages.map(\.sourceRange) == [0..<cut, cut..<specification.layers], "exact cut")
    }
    let stops = try QwenFullGenerationReferenceCLI(arguments: changed("--stop-token-ids", "[0,42,248319]"))
    try require(stops.stopTokenIDs == [0,42,248319], "explicit sorted stop IDs")
    for (flag, value) in [
        ("--mode", "other"), ("--registered-dense-profile", "unknown"),
        ("--prompt-count", "0"), ("--prompt-count", "8193"), ("--prompt-count", "01"),
        ("--chunk-size", "0"), ("--chunk-size", "513"), ("--model-dir", "relative"), ("--tokens-file", "relative"),
        ("--tokens-sha256", String(repeating: "A", count: 64)), ("--request-id", "not-a-uuid"),
        ("--stage-cut", "04"), ("--stage-cut", "5"), ("--stage-cut", "20"),
        ("--output-count", "0"), ("--output-count", "129"), ("--output-count", "01"),
        ("--timeout-seconds", "0"), ("--timeout-seconds", "301"),
        ("--stop-token-ids", "[true]"), ("--stop-token-ids", "[01]"),
        ("--stop-token-ids", "[-1]"), ("--stop-token-ids", "[248320]"),
        ("--stop-token-ids", "[2,1]"), ("--stop-token-ids", "[1,1]"), ("--stop-token-ids", "[1,]"),
    ] { try refuse { _ = try QwenFullGenerationReferenceCLI(arguments: changed(flag, value)) } }
    try refuse { _ = try QwenFullGenerationReferenceCLI(arguments: Array(arguments.dropLast())) }
    var duplicate = arguments; duplicate[0] = "--model-dir"
    try refuse { _ = try QwenFullGenerationReferenceCLI(arguments: duplicate) }
    reads = 0
    var badEnvironment = environment; badEnvironment["MLX_ENABLE_TF32"] = "0"
    try refuse { _ = try cli.preflight(environment: badEnvironment, read: { url, count in reads += 1; return try read(url, count) }) }
    try require(reads == 0, "arithmetic refused before file reads")
    try refuse { _ = try cli.preflight(environment: environment, read: { url, count in
        url.lastPathComponent == "manifest.json" ? manifest + Data([32]) : try read(url, count)
    }) }
    try refuse { _ = try cli.preflight(environment: environment, read: { url, count in
        url.lastPathComponent == "prompt.json" ? prompt + Data([32]) : try read(url, count)
    }) }
    let wrongCount = try QwenFullGenerationReferenceCLI(arguments: changed("--prompt-count", "8191"))
    try refuse { _ = try wrongCount.preflight(environment: environment, read: read) }
    let otherModel = model == .qwen35NineB ? QwenRegisteredDenseModel.qwen38TwentySevenB : .qwen35NineB
    let wrongModel = try QwenFullGenerationReferenceCLI(arguments: changed("--registered-dense-profile", otherModel.rawValue))
    try refuse { _ = try wrongModel.preflight(environment: environment, read: read) }
    let profile = try QwenRegisteredDenseModelProfile.admit(configuration: config, manifest: manifest,
        expectedArtifactAggregateSHA256: specification.artifactSHA256,
        canonicalTensors: tensors, residentDefinition: definition)
    let observed = tensors.map { QwenDenseObservedSourceTensor(canonical: $0, sourcePartCount: 1,
        preparedExpectedShape: $0.shape, constructorParameterIsPacked: $0.sourceDType == "U32") }
    let requirement = try QwenDenseStorageRequirement.derive(profile: profile, plan: input.admission.source.plan, role: .fullReference)
    let identity = QwenDenseObservedSourceIdentity(aggregateSHA256: specification.artifactSHA256,
        configurationSHA256: specification.configurationSHA256, verifiedManifestSHA256: specification.manifestSHA256,
        retainedSourceCount: tensors.count, bf16ConversionEnabled: true)
    let source = try QwenDenseObservedSourceValidation.validateRegistered(observed, identity: identity,
        profile: profile, requirement: requirement, plan: input.admission.source.plan)
    let admission = input.admission
    func budget(_ request: QwenLayerStageGenerationRequest, _ requirements: QwenGenerationReferenceRequirements,
                _ bound: (Int) throws -> Int) throws -> QwenFullGenerationReferenceBudget {
        try .derive(profile: profile, plan: admission.source.plan, request: request,
            requirements: requirements, source: source, bound: bound)
    }
    let logical = try budget(admission.request, admission.requirements, { $0 })
    let full = try QwenDenseStorageRequirement.derive(profile: profile, plan: admission.source.plan, role: .fullReference)
    let expectedFullState = model == .qwen35NineB ? 754_188_320 : 1_616_248_896
    try require(logical.stateBytes == expectedFullState && logical.fusionBytes == full.fusionReplacementBytes
        && logical.capturedRowsCPUBytes == 2_979_840 && logical.captureNativeBytes == 1_489_920,
        "full state once, both fusion banks, two CPU rows and one current native conversion")
    try require(logical.requestReservedBytes == expectedFullState + full.fusionReplacementBytes + 4_469_760,
        "combined request reserve")
    try require(try logical.remainingAllocationBytes(after: 0) == profile.sourceTensorBytes
        && logical.remainingAllocationBytes(after: specification.tensorCount) == 0, "full source allocation conservation")
    try require(try logical.requiredActualFreeBytes(after: 0) == max(6 * 1_073_741_824,
        profile.sourceTensorBytes + 2 * profile.largestSourceTensorBytes + logical.requestReservedBytes + 4 * 1_073_741_824), "load free formula")
    try require(try logical.requiredAllocatorBytes(after: specification.tensorCount, active: 100, cache: 200)
        == 300 + logical.stateBytes + logical.fusionBytes + 1_489_920 + 2 * 1_073_741_824, "host row excluded from allocator requirement")
    let padded = try budget(admission.request, admission.requirements, { $0 + 16_384 })
    try require(padded.requestReservedBytes > logical.requestReservedBytes
        && padded.allocationBounds[0] == logical.allocationBounds[0] + 16_384, "actual per-array bounds used")
    let short = try QwenFullGenerationReferenceCLI(arguments: changed("--output-count", "1")).preflight(environment: environment, read: read)
    let shortBudget = try budget(short.admission.request, short.admission.requirements, { $0 })
    try require(shortBudget.stateBytes < logical.stateBytes && short.admission.request.forwardCount == 16,
        "output-one state is not reused for O128")
    // Exercise an actual partial final chunk and a configured chunk larger
    // than the whole prompt. The ledger charges the largest executed frame.
    for (promptCount, chunkSize, outputCount) in [(1, 512, 1), (31, 16, 2), (513, 512, 128)] {
        let ids = Array(repeating: 17, count: promptCount)
        let data = try JSONEncoder().encode(ids)
        let value = try QwenRegisteredGenerationReferenceSource(definition: definition,
            configuration: config, manifest: manifest, promptData: data,
            expectedPromptSHA256: sha256(data), promptCount: promptCount, requestID: id,
            stageCut: 4, chunkSize: chunkSize, outputCount: outputCount,
            stopTokenIDs: [], arithmetic: QwenLongPrefillArithmeticEnvironment.admit(environment))
        let admitted = try QwenGenerationReferenceAdmission(source: value, request: value.request)
        let ledger = try budget(admitted.request, admitted.requirements, { $0 })
        let expected = try value.resource.namedStateBudget(maximumTokens: promptCount + outputCount,
            chunkSize: min(chunkSize, promptCount))
        try require(ledger.stateBytes == expected.conservativeStateAndBoundaryBytes
            && value.request.prefillFrameCount == (promptCount - 1) / chunkSize + 1,
            "short and partial-chunk budget follows actual maximum frame")
        let substituted = try QwenLayerStageGenerationRequest(profile: value.request.profile, requestID: id,
            promptTokenIDs: ids, chunkSize: chunkSize, outputCount: outputCount, stopTokenIDs: [17])
        try refuse { _ = try QwenGenerationReferenceAdmission(source: value, request: substituted) }
    }
    try refuse { _ = try budget(admission.request, short.admission.requirements, { $0 }) }
    try refuse { _ = try budget(admission.request, admission.requirements, { $0 - 1 }) }
    try refuse { _ = try budget(admission.request, admission.requirements, { _ in Int.max }) }
    enum Marker: Error { case original }
    do {
        _ = try budget(admission.request, admission.requirements, { _ in throw Marker.original })
        throw ProbeError("Allocator error was swallowed")
    } catch Marker.original { accepted += 1 }
    try logical.requireEntry(name: logical.sourceNames[0], byteCount: logical.sourceByteCounts[0], ordinal: 0)
    accepted += 1
    try refuse { try logical.requireEntry(name: logical.sourceNames[1], byteCount: logical.sourceByteCounts[1], ordinal: 0) }
    try refuse { try logical.requireEntry(name: logical.sourceNames[0], byteCount: logical.sourceByteCounts[0] - 1, ordinal: 0) }
    try refuse { _ = try logical.remainingAllocationBytes(after: -1) }
    try refuse { _ = try logical.remainingAllocationBytes(after: specification.tensorCount + 1) }
    return .init(accepted: accepted, rejected: rejected)
}
