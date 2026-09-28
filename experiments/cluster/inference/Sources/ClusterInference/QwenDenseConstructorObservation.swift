import Foundation
import MLX
import MLXNN

func observeQwenDenseConstructor(_ model: Module, role: String, layerCount: Int,
    configuration: Data
) throws -> QwenDenseConstructorObservation {
    let parameters = try model.parameters().flattened().sorted { $0.0 < $1.0 }.map { name, value in
        let bytes = try QwenLongPrefillCheckedBytes.product(value.shape + [value.dtype.size])
        guard value.nbytes == bytes, [.uint32, .float16, .bfloat16, .float32].contains(value.dtype) else {
            throw ProbeError("Unexpected constructor parameter scalar geometry or dtype")
        }
        return QwenDenseConstructorParameter(name: name, shape: value.shape,
            constructorDType: String(describing: value.dtype), logicalByteCount: bytes)
    }
    guard !parameters.isEmpty, parameters.count <= 2048,
          Set(parameters.map(\.name)).count == parameters.count else {
        throw ProbeError("Constructor parameter names are empty, duplicated or unbounded")
    }
    return .init(role: role, layerCount: layerCount, configurationSHA256: sha256(configuration),
        parameters: parameters, parameterMetadataSHA256: try QwenDenseProfileIdentity.encodedFingerprint(parameters),
        logicalParameterBytes: try QwenLongPrefillCheckedBytes.sum(parameters.map(\.logicalByteCount)),
        modelReleased: true)
}
