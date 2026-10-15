import Foundation
import MLX

struct ExpertAxisDifference: Encodable {
    let exactBytes: Bool
    let values: Int
    let maximumAbsoluteError: Double, relativeRMSError: Double
    let referenceSHA256: String, candidateSHA256: String
}

func compareExpertAxis(_ reference: MLXArray, _ candidate: MLXArray,
                       check: () throws -> Void) throws -> ExpertAxisDifference {
    guard reference.shape == candidate.shape, reference.dtype == candidate.dtype else {
        throw ProbeError("Expert output shape/dtype differs")
    }
    eval(reference, candidate); try check()
    let referenceBytes = reference.asData(access: .copy).data; try check()
    let candidateBytes = candidate.asData(access: .copy).data; try check()
    let a = reference.asType(.float32), b = candidate.asType(.float32)
    eval(a, b); try check()
    let expected = a.asArray(Float.self); try check()
    let actual = b.asArray(Float.self); try check()
    var maximum = 0.0, error = 0.0, norm = 0.0
    for (left, right) in zip(expected, actual) {
        guard left.isFinite, right.isFinite else { throw ProbeError("Nonfinite expert result") }
        let delta = Double(left) - Double(right)
        maximum = max(maximum, abs(delta)); error += delta * delta; norm += Double(left) * Double(left)
    }
    return .init(exactBytes: referenceBytes == candidateBytes, values: expected.count,
        maximumAbsoluteError: maximum, relativeRMSError: sqrt(error / max(norm, 1e-30)),
        referenceSHA256: sha256(referenceBytes), candidateSHA256: sha256(candidateBytes))
}

struct ExpertAxisCaseResult: Encodable {
    let label: String, inputDType: String
    let tokenCount: Int, topK: Int, assignmentCounts: [Int]
    let selectedGlobalIDs: [[Int]]
    let projectionPolicies: [ExpertAxisProjectionPolicy]
    let routingWeightsSHA256: String
    let expertOutputs: ExpertAxisDifference, weighted: ExpertAxisDifference
    let postNorm: ExpertAxisDifference?
    var passed: Bool { expertOutputs.exactBytes && weighted.exactBytes && (postNorm?.exactBytes ?? true) }
}
