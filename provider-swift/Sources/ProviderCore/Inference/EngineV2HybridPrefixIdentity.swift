import CryptoKit
import Foundation
import MLX
import MLXLMCommon

/// Restores the media binding from 317205e53. Token IDs remain in the
/// ordinary chain; this commits every evaluated out-of-band input that can
/// change recurrent state. It never logs or persists media plaintext.
enum EngineV2HybridPrefixIdentityBuilder {
    enum Failure: Error, Equatable { case invalidGeometry }
    private static let domain = "darkbloom.engine-v2.media-prefix.v1"
    private static let canonicalDomain = "darkbloom.engine-v2.media-prefix.qwen4-linear-tail.v2"

    static func make(
        spans: [CBv2ImageSpan], spanKinds: [EngineV2VisionPrefill.SpanKind],
        embeddings: [MLXArray], deepstackEmbeddings: [[MLXArray]],
        attention: CBv2MultimodalAttention, positionState: CBv2PositionState?,
        canonicalQwen4TextTail: Bool = false
    ) throws -> CBv2HybridPrefixIdentity {
        guard !spans.isEmpty, spans.count == spanKinds.count,
            spans.count == embeddings.count,
            deepstackEmbeddings.allSatisfy({ $0.count == spans.count }),
            spans.allSatisfy({ $0.tokenOffset >= 0 && $0.length > 0 })
        else { throw Failure.invalidGeometry }
        for index in spans.indices {
            let array = embeddings[index]
            guard array.ndim == 3, array.dim(0) == 1,
                array.dim(1) == spans[index].length, array.dim(2) > 0,
                deepstackEmbeddings.allSatisfy({ level in
                    let value = level[index]
                    return value.shape == array.shape
                })
            else { throw Failure.invalidGeometry }
        }
        let canonicalLength = canonicalQwen4TextTail && attention == .causal
            ? canonicalPositionLength(spans: spans, state: positionState) : nil
        var encoder = Encoder()
        encoder.append(canonicalLength == nil ? Self.domain : Self.canonicalDomain)
        encoder.append(UInt64(attention == .causal ? 1 : 2))
        encoder.append(UInt64(spans.count))
        for index in spans.indices {
            encoder.append(UInt64(spanKinds[index] == .image ? 1 : 2))
            encoder.append(spans[index].tokenOffset)
            encoder.append(spans[index].length)
            encoder.append(embeddings[index])
        }
        encoder.append(UInt64(deepstackEmbeddings.count))
        for level in deepstackEmbeddings {
            encoder.append(UInt64(level.count))
            for embedding in level { encoder.append(embedding) }
        }
        if let positionState {
            encoder.append(UInt64(1))
            encoder.append(positionState.axisCount)
            encoder.append(canonicalLength ?? positionState.promptLength)
            encoder.append(UInt64(positionState.decodeDeltas.count))
            for delta in positionState.decodeDeltas { encoder.append(delta) }
            if let canonicalLength {
                encoder.append(positionState.promptSlice(0 ..< canonicalLength))
            } else {
                encoder.append(positionState.promptPositionIds)
            }
        } else { encoder.append(UInt64(0)) }
        return try CBv2HybridPrefixIdentity(digest: encoder.finalize())
    }

    private static func canonicalPositionLength(
        spans: [CBv2ImageSpan], state: CBv2PositionState?
    ) -> Int? {
        guard let state, state.axisCount == 3, state.decodeDeltas.count == 1,
            state.promptPositionIds.dtype == .int32 || state.promptPositionIds.dtype == .int64
        else { return nil }
        var ranges: [Range<Int>] = []
        for span in spans {
            let (end, overflow) = span.tokenOffset.addingReportingOverflow(span.length)
            guard !overflow, span.tokenOffset >= 0, span.length > 0 else { return nil }
            ranges.append(span.tokenOffset ..< end)
        }
        if state.promptPositionIds.dtype == .int32 {
            return Qwen4CanonicalMediaPositions.prefixLength(
                positions: state.promptPositionIds.asArray(Int32.self), axes: state.axisCount,
                promptLength: state.promptLength, mediaRanges: ranges,
                decodeDelta: state.decodeDeltas[0])
        }
        return Qwen4CanonicalMediaPositions.prefixLength(
            positions: state.promptPositionIds.asArray(Int64.self), axes: state.axisCount,
            promptLength: state.promptLength, mediaRanges: ranges,
            decodeDelta: state.decodeDeltas[0])
    }

    private struct Encoder {
        private var hasher = SHA256()
        mutating func append(_ value: String) {
            let data = Data(value.utf8)
            append(UInt64(data.count)); hasher.update(data: data)
        }
        mutating func append(_ value: Int) {
            precondition(value >= 0)
            append(UInt64(value))
        }
        mutating func append(_ value: Int32) { append(UInt64(UInt32(bitPattern: value))) }
        mutating func append(_ value: UInt64) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { hasher.update(data: Data($0)) }
        }
        mutating func append(_ array: MLXArray) {
            append(UInt64(array.ndim))
            for dimension in array.shape { append(dimension) }
            append(String(describing: array.dtype))
            // Empty arrays have no native pointer; preserve their typed shape
            // without invoking the historical empty-asData invalid access.
            let bytes = array.size == 0 ? Data() : array.asData(access: .copy).data
            append(UInt64(bytes.count)); hasher.update(data: bytes)
        }
        mutating func finalize() -> Data { Data(hasher.finalize()) }
    }
}
