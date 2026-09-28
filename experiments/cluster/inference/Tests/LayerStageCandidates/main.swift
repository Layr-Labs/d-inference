import Foundation
import Darwin

struct CandidateTestResult: Encodable {
    let kind = "qwen_layer_stage_candidates_public_check"
    let cpuOnly = true
    let modelOrDescriptorRead = false
    let executionOrPerformanceQualified = false
    let ownershipCases: [String]
    let rejectedCases: [String]
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var bytes = try encoder.encode(value); bytes.append(10)
    FileHandle.standardOutput.write(bytes)
}

do {
    try emit(CandidateTestResult(ownershipCases: checkCandidateOwnership(), rejectedCases: checkCandidateRejections()))
    // Separate records, in this fixed order: direct text, then nested wrapper.
    for form in [CandidateFixture.Form.text, .nestedWrapper] {
        let fixture = CandidateFixture(layers: 12, form: form)
        try emit(checkQwenStageOutputGateMetadata(configuration: candidateJSON(fixture.object), ranges: [0..<4, 4..<12]))
    }
} catch {
    FileHandle.standardError.write(Data("candidate-metadata-check: \(error)\n".utf8))
    exit(1)
}
