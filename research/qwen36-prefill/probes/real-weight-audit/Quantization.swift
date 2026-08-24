import Darwin
import Foundation

enum QuantizationMode: String, Sendable {
    case affine
    case mxfp8
}

struct QuantizationPolicy: Sendable {
    let mode: QuantizationMode
    let bits: Int
    let groupSize: Int

    var decodeContract: String {
        switch mode {
        case .affine:
            return "mlx-pinned-bfloat16-multiply-then-bfloat16-add"
        case .mxfp8:
            return "mlx-e4m3-code-times-e8m0-scale-to-bfloat16"
        }
    }
}

struct QuantizationResolver {
    private let affineTable: [String: Any]
    private let mtpTable: [String: Any]

    init(config: [String: Any]) throws {
        guard
            let affine = (config["quantization_config"] ?? config["quantization"])
                as? [String: Any]
        else {
            throw AuditError.invalid("config has no quantization_config object")
        }
        guard let mtp = config["mtplx_mtp_quantization"] as? [String: Any] else {
            throw AuditError.invalid("config has no mtplx_mtp_quantization object")
        }
        affineTable = affine
        mtpTable = mtp
    }

    func policy(forWeightBase base: String) throws -> QuantizationPolicy {
        let isMTP = base.hasPrefix("mtp.")
        let table = isMTP ? mtpTable : affineTable
        let lookupPath = isMTP ? String(base.dropFirst("mtp.".count)) : base
        let override = table[lookupPath] as? [String: Any]

        guard
            let bits = (override?["bits"] ?? table["bits"]) as? NSNumber,
            let groupSize = (override?["group_size"] ?? table["group_size"]) as? NSNumber
        else {
            throw AuditError.invalid("\(base): incomplete quantization policy")
        }
        let modeName = (override?["mode"] ?? table["mode"] ?? "affine") as? String
        guard let modeName, let mode = QuantizationMode(rawValue: modeName) else {
            throw AuditError.invalid("\(base): unsupported quantization mode")
        }

        let policy = QuantizationPolicy(
            mode: mode,
            bits: bits.intValue,
            groupSize: groupSize.intValue
        )
        switch (policy.mode, policy.bits, policy.groupSize) {
        case (.affine, 4, 64), (.affine, 8, 64), (.mxfp8, 8, 32):
            return policy
        default:
            throw AuditError.invalid(
                "\(base): unsupported policy \(mode.rawValue)/\(policy.bits)/g\(policy.groupSize)"
            )
        }
    }
}

struct QuantizedTensor: @unchecked Sendable {
    let baseName: String
    let weight: MappedTensor
    let scales: MappedTensor
    let biases: MappedTensor?
    let policy: QuantizationPolicy
    let matrixCount: Int
    let rows: Int
    let columns: Int
    let groupsPerRow: Int
    let packedWordsPerRow: Int

    init(
        baseName: String,
        weight: MappedTensor,
        scales: MappedTensor,
        biases: MappedTensor?,
        policy: QuantizationPolicy
    ) throws {
        guard weight.location.dtype == "U32" else {
            throw AuditError.invalid("\(baseName): packed weights are not U32")
        }
        guard weight.location.shape.count == 2 || weight.location.shape.count == 3 else {
            throw AuditError.invalid(
                "\(baseName): expected a rank-2 dense or rank-3 expert tensor"
            )
        }

        let shape = weight.location.shape
        let rows = shape[shape.count - 2]
        let packedWords = shape[shape.count - 1]
        let matrixCount = shape.dropLast(2).reduce(1, *)
        let columns = packedWords * 32 / policy.bits
        guard columns % policy.groupSize == 0 else {
            throw AuditError.invalid("\(baseName): K is not divisible by group size")
        }
        let groups = columns / policy.groupSize
        let expectedMetadataShape = Array(shape.dropLast()) + [groups]
        guard scales.location.shape == expectedMetadataShape else {
            throw AuditError.invalid(
                "\(baseName): scale shape \(scales.location.shape) != \(expectedMetadataShape)"
            )
        }

        switch policy.mode {
        case .affine:
            guard scales.location.dtype == "BF16" else {
                throw AuditError.invalid("\(baseName): affine scales are not BF16")
            }
            guard let biases else {
                throw AuditError.invalid("\(baseName): affine tensor has no biases")
            }
            guard
                biases.location.dtype == "BF16",
                biases.location.shape == expectedMetadataShape
            else {
                throw AuditError.invalid("\(baseName): affine bias metadata is malformed")
            }
        case .mxfp8:
            guard scales.location.dtype == "U8", biases == nil else {
                throw AuditError.invalid(
                    "\(baseName): MXFP8 requires U8 scales and no biases"
                )
            }
        }

        self.baseName = baseName
        self.weight = weight
        self.scales = scales
        self.biases = biases
        self.policy = policy
        self.matrixCount = matrixCount
        self.rows = rows
        self.columns = columns
        groupsPerRow = groups
        packedWordsPerRow = packedWords
    }

    var isExpertTensor: Bool {
        weight.location.shape.count == 3
    }

    @inline(__always)
    func rawCode(matrix: Int, row: Int, column: Int) -> UInt8 {
        let rowByteOffset =
            ((matrix &* rows &+ row) &* packedWordsPerRow) &* MemoryLayout<UInt32>.size
        if policy.bits == 8 {
            return weight.uint8(at: rowByteOffset + column)
        }
        let packed = weight.uint8(at: rowByteOffset + column / 2)
        return column & 1 == 0 ? packed & 0x0f : packed >> 4
    }

    @inline(__always)
    func rawScale(matrix: Int, row: Int, group: Int) -> UInt16 {
        let index = (matrix &* rows &+ row) &* groupsPerRow &+ group
        if policy.mode == .mxfp8 {
            return UInt16(scales.uint8(at: index))
        }
        return scales.uint16LE(at: index)
    }

    @inline(__always)
    func rawBias(matrix: Int, row: Int, group: Int) -> UInt16? {
        guard let biases else { return nil }
        let index = (matrix &* rows &+ row) &* groupsPerRow &+ group
        return biases.uint16LE(at: index)
    }

    @inline(__always)
    func decodedBits(matrix: Int, row: Int, column: Int) -> UInt16 {
        let group = column / policy.groupSize
        let code = rawCode(matrix: matrix, row: row, column: column)
        switch policy.mode {
        case .affine:
            return affineDecodedBF16(
                code: code,
                scale: rawScale(matrix: matrix, row: row, group: group),
                bias: rawBias(matrix: matrix, row: row, group: group)!
            )
        case .mxfp8:
            return mxfp8DecodedBF16(
                code: code,
                scale: UInt8(
                    truncatingIfNeeded: rawScale(matrix: matrix, row: row, group: group)
                )
            )
        }
    }
}

@inline(__always)
func bf16ToFloat(_ bits: UInt16) -> Float {
    Float(bitPattern: UInt32(bits) << 16)
}

@inline(__always)
func floatToBF16RoundToNearestEven(_ value: Float) -> UInt16 {
    let bits = value.bitPattern
    if bits & 0x7f80_0000 == 0x7f80_0000 {
        if bits & 0x007f_ffff == 0 {
            return UInt16(truncatingIfNeeded: bits >> 16)
        }
        return UInt16(truncatingIfNeeded: (bits >> 16) | 0x0040)
    }
    let roundingBias = UInt32(0x7fff) + ((bits >> 16) & 1)
    return UInt16(truncatingIfNeeded: (bits &+ roundingBias) >> 16)
}

@inline(__always)
func affineDecodedBF16(code: UInt8, scale: UInt16, bias: UInt16) -> UInt16 {
    // This deliberately mirrors the root repository's pinned MLX gitlink
    // (0a725e30), where U is bfloat16_t. The multiply rounds to BF16 before
    // the BF16 add. The later local FP32-dequant experiment is not the
    // shipping numerical contract audited here.
    let product = bf16ToFloat(scale) * Float(code)
    let roundedProduct = bf16ToFloat(floatToBF16RoundToNearestEven(product))
    return floatToBF16RoundToNearestEven(roundedProduct + bf16ToFloat(bias))
}

@inline(__always)
func mxfp8DecodedFloat(code: UInt8, scale: UInt8) -> Float {
    let magnitudeCode = Int(code & 0x7f)
    let exponent = magnitudeCode >> 3
    let mantissa = magnitudeCode & 0x7
    let magnitude: Float
    if exponent == 0 {
        magnitude = scalbnf(Float(mantissa), -9)
    } else {
        magnitude = scalbnf(Float(8 + mantissa), Int32(exponent - 10))
    }
    let signed = code & 0x80 == 0 ? magnitude : -magnitude
    if scale == 0 {
        return scalbnf(signed, -127)
    }
    if scale == 0xff {
        return signed == 0 ? .nan : signed.sign == .minus ? -.infinity : .infinity
    }
    return scalbnf(signed, Int32(Int(scale) - 127))
}

@inline(__always)
func mxfp8DecodedBF16(code: UInt8, scale: UInt8) -> UInt16 {
    floatToBF16RoundToNearestEven(mxfp8DecodedFloat(code: code, scale: scale))
}
