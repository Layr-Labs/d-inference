import Foundation

struct GDNArithmeticVariants: Encodable {
    let schemaVersion = 1
    let estimatedAdditionalTensorAndCaptureBytes: Int
    let estimatedAdditionalByteLimit = 512 * 1024 * 1024
    let estimateIsNotWholeProcessPeakBound = true
    let float32: GDNFloat32ProjectionVariant
    let paddedNative: GDNPaddedProjectionVariant
}

struct GDNFloat32ProjectionVariant: Encodable {
    let kind = "float32_projection"
    let metadataConversion = "original stored floating values widened to Float32"
    let evaluations: [GDNFloat32ProjectionEvaluation]
}

struct GDNFloat32ProjectionEvaluation: Encodable {
    let rank: Int?
    let input: GDNProjectionTensorIdentity
    let fusedWeight: GDNProjectionTensorIdentity
    let fusedScales: GDNProjectionTensorIdentity
    let fusedBiases: GDNProjectionTensorIdentity
    let selections: [GDNProjectionSelection]
    let selectionSHA256: String
    let components: [GDNProjectionComponent]
    let output: GDNProjectionValues
    let nativeCastOutput: GDNProjectionValues
}

struct GDNPaddedProjectionVariant: Encodable {
    let kind = "end_zero_rows"
    let evaluations: [GDNPaddedProjectionEvaluation]
}

struct GDNPaddedProjectionEvaluation: Encodable {
    let rank: Int
    let realRows: Int
    let paddedRows: Int
    let appendedZeroRows: Int
    let cropRows: [Int]
    let zeroPaddingValidated: Bool
    let input: GDNProjectionTensorIdentity
    let selections: [GDNProjectionSelection]
    let selectionSHA256: String
    let components: [GDNProjectionComponent]
    let fusedWeight: GDNProjectionTensorIdentity
    let fusedScales: GDNProjectionTensorIdentity
    let fusedBiases: GDNProjectionTensorIdentity
    let paddedOutput: GDNProjectionValues
    let output: GDNProjectionValues
}
