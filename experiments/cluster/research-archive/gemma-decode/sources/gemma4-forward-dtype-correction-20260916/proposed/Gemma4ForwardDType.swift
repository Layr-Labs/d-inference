import Foundation

/// Raw safetensors labels remain in artifact identities. Native parameter
/// names are projected explicitly; neither projection predicts activation/KV types.
enum Gemma4ForwardDType: String {
    case uint32 = "U32", float32 = "F32", float16 = "F16", bfloat16 = "BF16"

    init(safetensorsName: String) throws {
        guard let value = Self(rawValue: safetensorsName) else {
            throw ProbeError("Unsupported Gemma safetensors dtype")
        }
        self = value
    }

    var nativeSourceName: String {
        switch self {
        case .uint32: return "uint32"
        case .float32: return "float32"
        case .float16: return "float16"
        case .bfloat16: return "bfloat16"
        }
    }

    var nativeLoadedName: String { self == .float16 ? "bfloat16" : nativeSourceName }
    var requiresFloat32ParameterCast: Bool { self == .float16 || self == .bfloat16 }

    func acceptsConstructor(nativeName: String) -> Bool {
        self == .uint32 ? nativeName == "uint32" : ["float16", "bfloat16", "float32"].contains(nativeName)
    }
}
