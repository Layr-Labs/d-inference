import Foundation

/// The constants a Prism Hadamard stage adds to itself on its first forward.
/// Every packed projection receives F32 input (the first norm promotes the
/// stream), and under the pack's arithmetic contract it keeps one F32 copy of
/// its stored F16 scales and of its stored F16 biases for reuse. The copies
/// stay for as long as the stage does. The packed embedding makes no such
/// copy: it dequantizes the looked-up rows directly.
enum QwenPrismHadamardConstants {
    /// The logical bytes of each F32 copy one rank's stage will hold, in
    /// canonical name order: twice the stored bytes of each F16 tensor.
    static func widenedBytes(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                             rank: Int) throws -> [Int] {
        let tensors = Dictionary(uniqueKeysWithValues: profile.canonicalTensors.map { ($0.name, $0) })
        let embedding = QwenPrismStageConfiguration.namespace + QwenPrismStageConfiguration.embeddingPath + "."
        return try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
            .filter { $0.stage == rank && !$0.sourceName.hasPrefix(embedding)
                && ($0.sourceName.hasSuffix(".scales") || $0.sourceName.hasSuffix(".biases")) }
            .map { parameter in
                guard let tensor = tensors[parameter.sourceName], tensor.sourceDType == "F16", tensor.shape.count == 2 else {
                    throw ProbeError("Prism packed constant is not a stored F16 matrix: \(parameter.sourceName)")
                }
                return try QwenLongPrefillCheckedBytes.product([tensor.byteCount, 2])
            }
    }
}
