import Foundation

struct QwenResidentSoloCLI {
    static let mode = "qwen-resident-solo-generation"
    let reference: QwenFullGenerationReferenceCLI
    let expectedTokensFile: URL
    let expectedTokensSHA256: String
    let measuredCount: Int

    init(arguments: [String]) throws {
        guard arguments.count == 28 || arguments.count == 30 else {
            throw ProbeError("Resident solo requires fourteen option pairs and an optional measured count")
        }
        var base: [String] = [], expectedPath: String?, expectedSHA: String?
        var seen = Set<String>()
        var measured = 3
        for i in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[i], value = arguments[i+1]
            guard seen.insert(key).inserted, !value.isEmpty, value.utf8.count <= 4096,
                  !value.utf8.contains(0) else { throw ProbeError("Repeated or invalid solo option") }
            switch key {
            case "--measured-count":
                guard ["1", "2", "3"].contains(value), let count = Int(value) else {
                    throw ProbeError("Solo measured count must be1...3")
                }
                measured = count
            case "--expected-token-ids-file": expectedPath = value
            case "--expected-token-ids-sha256": expectedSHA = value
            case "--mode":
                guard value == Self.mode else { throw ProbeError("Wrong resident solo namespace") }
                base += [key, QwenFullGenerationReferenceCLI.mode]
            default: base += [key,value]
            }
        }
        guard let expectedPath, expectedPath.hasPrefix("/"), let expectedSHA,
              qwenStageWireIsSHA256(expectedSHA) else { throw ProbeError("Solo expected IDs need an absolute pinned input") }
        let value = try QwenFullGenerationReferenceCLI(arguments: base)
        let scope = try QwenResidentSoloModelScope(definition: value.definition)
        guard value.stageCut == scope.referenceCut,
              value.promptCount == 8192, value.chunkSize == 512, value.outputCount == 128,
              value.stopTokenIDs.isEmpty else { throw ProbeError("Resident solo requires the selected registered model/cut and matched 8192/512/128 request") }
        reference = value; measuredCount = measured
        expectedTokensFile = URL(fileURLWithPath: expectedPath); expectedTokensSHA256 = expectedSHA
    }

    func preflight(environment: [String:String], read: (URL,Int) throws -> Data,
                   makeUUID: () -> UUID = UUID.init) throws -> QwenResidentSoloPreflight {
        var prompt: Data?
        let first = try reference.preflight(environment: environment, read: { url, cap in
            let data = try read(url,cap)
            if url == reference.tokensFile { prompt = data }
            return data
        })
        let raw = try read(expectedTokensFile,16_384)
        guard !raw.isEmpty, raw.count <= 16_384, sha256(raw) == expectedTokensSHA256,
              let prompt else { throw ProbeError("Resident solo expected IDs or retained prompt differs") }
        try validateWorkerJSON(raw)
        let expected = try JSONDecoder().decode([Int].self,from: raw)
        guard expected.count == 128, expected.allSatisfy({ (0..<248_320).contains($0) }) else {
            throw ProbeError("Resident solo requires exactly128 valid expected target IDs")
        }
        let source = first.admission.source
        var requests = [first.admission]
        for _ in 0..<measuredCount {
            let next = try QwenRegisteredGenerationReferenceSource(definition: source.definition,
                configuration: source.configuration, manifest: source.manifest, promptData: prompt,
                expectedPromptSHA256: source.promptFileSHA256, promptCount: 8192, requestID: makeUUID(),
                stageCut: reference.stageCut, chunkSize: 512, outputCount: 128, stopTokenIDs: [], arithmetic: source.arithmetic)
            requests.append(try .init(source: next, request: next.request))
        }
        return try .init(first: first, requests: requests, expectedTokenIDs: expected,
            expectedTokenFileSHA256: expectedTokensSHA256, measuredCount: measuredCount)
    }
}

struct QwenResidentSoloPreflight {
    let first: QwenFullGenerationReferencePreflight
    let requests: [QwenGenerationReferenceAdmission]
    let expectedTokenIDs: [Int]
    let expectedTokenFileSHA256: String
    let warmupCount = 1
    let measuredCount: Int

    init(first: QwenFullGenerationReferencePreflight, requests: [QwenGenerationReferenceAdmission],
         expectedTokenIDs: [Int], expectedTokenFileSHA256: String, measuredCount: Int = 3) throws {
        let base = first.admission
        let scope = try QwenResidentSoloModelScope(definition: base.source.definition)
        guard base.source.plan.stages.map(\.sourceRange) ==
                [0..<scope.referenceCut, scope.referenceCut..<base.source.specification.layers],
              (1...3).contains(measuredCount), requests.count == 1 + measuredCount,
              Set(requests.map { $0.request.requestID }).count == requests.count,
              requests[0].request.requestID == base.request.requestID,
              expectedTokenIDs.count == 128, expectedTokenIDs.allSatisfy({ (0..<248_320).contains($0) }),
              qwenStageWireIsSHA256(expectedTokenFileSHA256) else {
            throw ProbeError("Resident solo cohort identity/count differs")
        }
        for next in requests {
            guard next.source.configuration == base.source.configuration,
                  next.source.manifest == base.source.manifest,
                  next.source.specification.model == scope.model,
                  next.source.plan.fingerprint == base.source.plan.fingerprint,
                  next.source.arithmetic == base.source.arithmetic,
                  next.source.promptFileSHA256 == base.source.promptFileSHA256,
                  next.request.promptTokenIDs == base.request.promptTokenIDs,
                  next.request.profile == base.request.profile,
                  next.request.promptCount == 8192, next.request.chunkSize == 512,
                  next.request.outputCount == 128, next.request.maximumTokens == 8320,
                  next.request.stopTokenIDs.isEmpty,
                  try canonicalJSONData(next.requirements.namedTensors) == canonicalJSONData(base.requirements.namedTensors),
                  next.requirements.capturedRowsCPUBytes == base.requirements.capturedRowsCPUBytes,
                  next.requirements.temporaryFloat32RowBytes == base.requirements.temporaryFloat32RowBytes,
                  next.requirements.namedTensorByteCeiling == base.requirements.namedTensorByteCeiling else {
                throw ProbeError("Resident solo cohort source, history or resource shape was substituted")
            }
        }
        self.first = first; self.requests = requests; self.expectedTokenIDs = expectedTokenIDs
        self.expectedTokenFileSHA256 = expectedTokenFileSHA256; self.measuredCount = measuredCount
    }
}
