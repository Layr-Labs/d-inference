import Foundation
import MLX
import MLXNN

func observedQwenDenseSource(_ prepared: PreparedQwenCheckpoint,
                             model: Module) -> [QwenDenseObservedSourceTensor] {
    let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
    return prepared.canonical.keys.sorted().map { name in
        let tensor = prepared.canonical[name]!
        let dtype: String
        switch tensor.dtype {
        case .uint32: dtype = "U32"
        case .float16: dtype = "F16"
        case .bfloat16: dtype = "BF16"
        case .float32: dtype = "F32"
        default: dtype = "unsupported"
        }
        return .init(canonical: .init(name: name, shape: tensor.shape,
            sourceDType: dtype, byteCount: tensor.byteCount), sourcePartCount: tensor.parts.count,
            preparedExpectedShape: prepared.expectedShapes[name],
            constructorParameterIsPacked: parameters[name].map { $0.dtype == .uint32 })
    }
}
