import Foundation
import MLX

struct GDNProjectionTensorIdentity: Encodable {
    let shape: [Int]
    let dtype: String
    let logicalBytesSHA256: String

    init(_ array: MLXArray, check: () throws -> Void) throws {
        eval(array)
        try check()
        shape = array.shape
        dtype = String(describing: array.dtype)
        logicalBytesSHA256 = sha256(array.asData(access: .noCopyIfContiguous).data)
        try check()
    }
}

struct GDNProjectionValues: Encodable {
    let shape: [Int]
    let dtype: String
    let logicalBytesSHA256: String
    let values: [Float]

    init(_ array: MLXArray, maximumValues: Int, check: () throws -> Void) throws {
        guard array.size > 0, array.size <= maximumValues,
              [DType.float16, .bfloat16, .float32].contains(array.dtype) else {
            throw ProbeError("GDN projection values exceed their bound or have an unsupported dtype")
        }
        let identity = try GDNProjectionTensorIdentity(array, check: check)
        let floating = array.asType(.float32)
        eval(floating)
        try check()
        let values = floating.asArray(Float.self)
        try check()
        guard values.allSatisfy(\.isFinite) else { throw ProbeError("Nonfinite GDN projection diagnostic values") }
        shape = identity.shape; dtype = identity.dtype
        logicalBytesSHA256 = identity.logicalBytesSHA256; self.values = values
    }
}

struct GDNProjectionSource: Encodable {
    let name: String
    let modulePath: String
    let inputWidth: Int
    let outputRows: Int
    let bits = 4
    let groupSize = 64
    let mode = "affine"
    let weight: GDNProjectionTensorIdentity
    let scales: GDNProjectionTensorIdentity
    let biases: GDNProjectionTensorIdentity
}

struct GDNProjectionSelection: Encodable {
    let name: String
    let axis = 0
    let ranges: [[Int]]
}

/// Offsets in the original fused output and in this rank's reconstructed output.
struct GDNProjectionComponent: Encodable {
    let name: String
    let sourceRows: [Int]
    let localRows: [Int]
}

struct GDNProjectionEvaluation: Encodable {
    let rank: Int?
    let output: GDNProjectionValues
    let selections: [GDNProjectionSelection]
    let selectionSHA256: String
    let fusedWeight: GDNProjectionTensorIdentity
    let fusedScales: GDNProjectionTensorIdentity
    let fusedBiases: GDNProjectionTensorIdentity
    let components: [GDNProjectionComponent]
}

struct GDNProjectionBF16Steps: Encodable {
    let definition = "absolute distance between ordered finite BF16 values; signed zeros coincide"
    let maximumAbsoluteSteps: Int
    let meanAbsoluteSteps: Double
    let oneStepDifferences: Int
    let greaterThanOneStepDifferences: Int
}

struct GDNProjectionDifference: Encodable {
    let rank: Int
    let component: String
    let comparedValues: Int
    let exactValues: Bool
    let differingValues: Int
    let maximumAbsoluteError: Double
    let rootMeanSquareError: Double
    let relativeRMSError: Double
    let bfloat16Steps: GDNProjectionBF16Steps?

    init(rank: Int, component: String, reference: [Float], candidate: [Float], dtype: String) throws {
        guard !reference.isEmpty, reference.count == candidate.count,
              reference.allSatisfy(\.isFinite), candidate.allSatisfy(\.isFinite) else {
            throw ProbeError("GDN projection comparison received inconsistent or nonfinite values")
        }
        var different = 0, maximum = 0.0, squares = 0.0, referenceSquares = 0.0
        var maximumSteps = 0, totalSteps = 0, oneStep = 0, largerSteps = 0
        func orderedBF16(_ value: Float) throws -> Int {
            guard value.bitPattern & 0xffff == 0 else {
                throw ProbeError("Claimed BF16 projection value is not exactly representable")
            }
            let bits = Int(value.bitPattern >> 16)
            return bits & 0x8000 == 0 ? 0x8000 + bits : 0x8000 - (bits & 0x7fff)
        }
        for (a, b) in zip(reference, candidate) {
            let difference = Double(b) - Double(a)
            if a != b { different += 1 }
            maximum = max(maximum, abs(difference))
            squares += difference * difference
            referenceSquares += Double(a) * Double(a)
            if dtype == "bfloat16" {
                let steps = abs(try orderedBF16(a) - orderedBF16(b))
                maximumSteps = max(maximumSteps, steps); totalSteps += steps
                if steps == 1 { oneStep += 1 }
                if steps > 1 { largerSteps += 1 }
            }
        }
        self.rank = rank; self.component = component
        comparedValues = reference.count; differingValues = different; exactValues = different == 0
        maximumAbsoluteError = maximum
        rootMeanSquareError = sqrt(squares / Double(reference.count))
        relativeRMSError = sqrt(squares / max(referenceSquares, 1e-30))
        bfloat16Steps = dtype == "bfloat16" ? GDNProjectionBF16Steps(
            maximumAbsoluteSteps: maximumSteps, meanAbsoluteSteps: Double(totalSteps) / Double(reference.count),
            oneStepDifferences: oneStep, greaterThanOneStepDifferences: largerSteps) : nil
    }
}

func compareGDNProjectionComponents(full: GDNProjectionEvaluation,
                                    rank: GDNProjectionEvaluation) throws -> [GDNProjectionDifference] {
    guard let index = rank.rank, (0..<2).contains(index), full.output.shape.count == 3,
          rank.output.shape.count == 3, full.output.shape[0...1] == rank.output.shape[0...1],
          full.output.dtype == rank.output.dtype else { throw ProbeError("Invalid full/rank projection geometry") }
    let rows = full.output.shape[0] * full.output.shape[1]
    let fullWidth = full.output.shape[2], localWidth = rank.output.shape[2]
    return try rank.components.map { component in
        let source = component.sourceRows, local = component.localRows
        guard source.count == 2, local.count == 2,
              source[0] >= 0, source[1] <= fullWidth, local[0] >= 0, local[1] <= localWidth,
              source[1] > source[0], source[1] - source[0] == local[1] - local[0] else {
            throw ProbeError("Invalid GDN semantic component interval")
        }
        var a: [Float] = [], b: [Float] = []
        a.reserveCapacity(rows * (source[1] - source[0])); b.reserveCapacity(a.capacity)
        for row in 0..<rows {
            a.append(contentsOf: full.output.values[(row * fullWidth + source[0])..<(row * fullWidth + source[1])])
            b.append(contentsOf: rank.output.values[(row * localWidth + local[0])..<(row * localWidth + local[1])])
        }
        return try GDNProjectionDifference(rank: index, component: component.name,
                                            reference: a, candidate: b, dtype: full.output.dtype)
    }
}
