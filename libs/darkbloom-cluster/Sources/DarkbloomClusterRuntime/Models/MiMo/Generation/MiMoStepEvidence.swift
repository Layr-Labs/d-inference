import Foundation

/// What stage 1 can say about one logits row a token was selected from, read
/// from the bytes it already copies for its row digest: the residual that
/// entered the frame, the row's digest and its highest candidates with their
/// exact values. Enough to place two runs' first difference (which frame,
/// whether the residual or only the row differs) and to tell a near tie from
/// a real divergence, without moving a tensor. Qualification evidence only.
public struct MiMoStepEvidence: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public let tokenID: Int
        /// The candidate's logit widened to float32 (exact for bfloat16 and float16 rows).
        public let logit: Float
        /// `logit`'s float32 bit pattern, lowercase hexadecimal, eight digits.
        public let logitBits: String
    }

    public static let linePrefix = "darkbloom-mimo-step-v1"
    public static let candidateCount = 4
    /// Digest prefix length a runtime line carries (64 bits); reports keep the full digest.
    public static let lineDigestCharacters = 16

    /// Index of the logits row in this request, equal to the selected token's ordinal.
    public let ordinal: Int
    public let boundarySHA256: String
    public let rowSHA256: String
    public let rowDType: String
    /// Highest first; equal values in ascending token order.
    public let top: [Candidate]

    public init(ordinal: Int, boundarySHA256: String, rowSHA256: String, rowDType: String, top: [Candidate]) {
        self.ordinal = ordinal; self.boundarySHA256 = boundarySHA256; self.rowSHA256 = rowSHA256
        self.rowDType = rowDType; self.top = top
    }

    /// Top candidates of one row from its raw little-endian bytes. `dtype` is
    /// the row's MLX dtype name (`bfloat16`, `float16` or `float32`).
    public static func candidates(rowBytes data: Data, dtype: String, count: Int = candidateCount) throws -> [Candidate] {
        let width: Int
        switch dtype {
        case "bfloat16", "float16": width = 2
        case "float32": width = 4
        default: throw ProbeError("MiMo step evidence reads bfloat16, float16 or float32 rows, not \(dtype)")
        }
        guard count > 0, !data.isEmpty, data.count % width == 0 else {
            throw ProbeError("MiMo step evidence row bytes do not form whole elements")
        }
        let elements = data.count / width
        var best: [(id: Int, value: Float)] = []
        best.reserveCapacity(count + 1)
        data.withUnsafeBytes { raw in
            for index in 0..<elements {
                let value: Float
                switch width {
                case 4: value = Float(bitPattern: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian)
                default:
                    let half = raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian
                    value = dtype == "bfloat16" ? Float(bitPattern: UInt32(half) << 16) : Float(Float16(bitPattern: half))
                }
                // NaN never ranks; a row with one is reported by its digest.
                guard !value.isNaN else { continue }
                if best.count == count, let last = best.last, value <= last.value { continue }
                var at = best.count
                while at > 0 && best[at - 1].value < value { at -= 1 }
                best.insert((index, value), at: at)
                if best.count > count { best.removeLast() }
            }
        }
        return best.map {
            Candidate(tokenID: $0.id, logit: $0.value, logitBits: String(format: "%08x", $0.value.bitPattern))
        }
    }

    /// One runtime line: lowercase letters, digits, spaces, '-', '=' and '_'
    /// only, as the pair driver keeps it.
    public func line(rank: Int) -> String {
        let digits = Self.lineDigestCharacters
        let top = self.top.map { "\($0.tokenID)_\($0.logitBits)" }.joined(separator: "_")
        return [Self.linePrefix, "rank=\(rank)", "i=\(ordinal)",
                "boundary=\(boundarySHA256.prefix(digits))", "row=\(rowSHA256.prefix(digits))",
                "dtype=\(rowDType)", "top=\(top)"].joined(separator: " ")
    }
}
