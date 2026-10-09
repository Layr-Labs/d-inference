import Foundation

/// Rank 0's side of a hand-off, as CPU values: the committed producer state as
/// logical bytes with one digest per component. It performs no IO. The pair
/// sends its header and segments over the link; the single-Mac reference moves
/// the same bytes across an in-process boundary.
struct QwenPhaseSplitHandoffSender {
    struct Component {
        let shape: QwenPhaseSplitStateShape
        let sha256: String
        /// Row-major logical bytes; absent for a component that is not sent.
        let bytes: Data?
    }
    let header: QwenPhaseSplitHandoffHeader
    let segments: [QwenPhaseSplitSegment]
    let logicalBytes: Int
    private let components: [Component]

    /// The components must be the agreed manifest, in order: the producer
    /// refuses its own state before anything is sent if it differs. Each
    /// digest is the one the state snapshot computed over these same bytes; it
    /// is not recomputed here, because the adopting rank checks every byte it
    /// receives against it and refuses the hand-off if they differ.
    init(agreement: QwenLayerStageGenerationAgreement, tokenChainSHA256: String, components: [Component]) throws {
        guard let split = agreement.phaseSplit, components.map(\.shape) == split.shapes else {
            throw ProbeError("Producer state differs from the agreed hand-off manifest")
        }
        let transferred = Set(split.segments.map(\.entryIndex))
        for (index, component) in components.enumerated() {
            guard transferred.contains(index) == (component.bytes != nil),
                  component.bytes.map({ $0.count == component.shape.byteCount }) ?? true else {
                throw ProbeError("Producer state bytes are missing or differ from their agreed size")
            }
        }
        header = try .init(agreement: agreement, tokenChainSHA256: tokenChainSHA256, digests: components.map(\.sha256))
        segments = split.segments; logicalBytes = split.terms.logicalBytes
        self.components = components
    }

    /// The row-major bytes of one segment.
    func bytes(for segment: QwenPhaseSplitSegment) throws -> Data {
        guard components.indices.contains(segment.entryIndex), let bytes = components[segment.entryIndex].bytes else {
            throw ProbeError("Hand-off segment names a component that is not sent")
        }
        guard let tokens = segment.tokens else { return bytes }
        return try QwenPhaseSplitSlab.extract(bytes, shape: components[segment.entryIndex].shape, tokens: tokens)
    }
}

/// Token-axis slabs of a `[1, heads, tokens, width]` tensor in row-major bytes.
enum QwenPhaseSplitSlab {
    private static func geometry(_ shape: QwenPhaseSplitStateShape, _ tokens: Range<Int>) throws -> (heads: Int, total: Int, row: Int) {
        guard shape.shape.count == 4, shape.shape[0] == 1, !tokens.isEmpty,
              tokens.lowerBound >= 0, tokens.upperBound <= shape.shape[2] else {
            throw ProbeError("Hand-off slab is outside its attention tensor")
        }
        let row = shape.shape[3] * (try QwenPhaseSplitStateShape.elementBytes(shape.dtype))
        guard shape.byteCount == shape.shape[1] * shape.shape[2] * row else { throw ProbeError("Hand-off slab geometry differs") }
        return (shape.shape[1], shape.shape[2], row)
    }

    static func extract(_ bytes: Data, shape: QwenPhaseSplitStateShape, tokens: Range<Int>) throws -> Data {
        let g = try geometry(shape, tokens)
        guard bytes.count == shape.byteCount else { throw ProbeError("Hand-off slab source size differs") }
        var slab = Data(capacity: g.heads * tokens.count * g.row)
        for head in 0..<g.heads {
            let start = bytes.startIndex + (head * g.total + tokens.lowerBound) * g.row
            slab.append(bytes[start..<(start + tokens.count * g.row)])
        }
        return slab
    }

    static func place(_ slab: Data, into bytes: inout Data, shape: QwenPhaseSplitStateShape, tokens: Range<Int>) throws {
        let g = try geometry(shape, tokens)
        guard bytes.count == shape.byteCount, slab.count == g.heads * tokens.count * g.row else {
            throw ProbeError("Hand-off slab size differs")
        }
        for head in 0..<g.heads {
            let source = slab.startIndex + head * tokens.count * g.row
            let target = bytes.startIndex + (head * g.total + tokens.lowerBound) * g.row
            bytes.replaceSubrange(target..<(target + tokens.count * g.row), with: slab[source..<(source + tokens.count * g.row)])
        }
    }
}

/// Rank 1's side: the header is checked against the local expectation, then
/// every component's bytes against the header's digest. A digest that differs
/// is recorded and the remaining segments are still accepted, so the sender is
/// never left blocked in a transfer; `finish` then refuses the hand-off.
final class QwenPhaseSplitHandoffReceiver {
    let agreement: QwenLayerStageGenerationAgreement
    let split: QwenPhaseSplitPlan
    private let tokenChainSHA256: String
    private(set) var header: QwenPhaseSplitHandoffHeader?
    private(set) var refusal: String?
    private var nextSegment = 0
    private var partial: Data?
    private var verified: [Int: Data] = [:]
    var segments: [QwenPhaseSplitSegment] { split.segments }
    var complete: Bool { header != nil && nextSegment == split.segments.count }

    init(agreement: QwenLayerStageGenerationAgreement, tokenChainSHA256: String) throws {
        guard let split = agreement.phaseSplit, qwenStageWireIsSHA256(tokenChainSHA256) else {
            throw ProbeError("Hand-off receive requires a phase-split agreement")
        }
        self.agreement = agreement; self.split = split; self.tokenChainSHA256 = tokenChainSHA256
    }

    /// Throws when the header is not exactly what this rank expects: another
    /// request, frontier, history, size or component list.
    func acceptHeader(_ data: Data) throws {
        guard header == nil, refusal == nil else { throw ProbeError("Hand-off header repeated") }
        do {
            header = try .decode(data, agreement: agreement, tokenChainSHA256: tokenChainSHA256)
        } catch {
            refusal = "header: \(error)"
            throw error
        }
    }

    /// Segments arrive in the agreed order with the agreed sizes.
    func acceptSegment(_ index: Int, bytes: Data) throws {
        guard let header, index == nextSegment, split.segments.indices.contains(index) else {
            throw ProbeError("Hand-off segment is out of order or precedes its header")
        }
        let segment = split.segments[index], shape = split.shapes[segment.entryIndex]
        guard bytes.count == segment.byteCount else { throw ProbeError("Hand-off segment size differs from the agreed manifest") }
        nextSegment += 1
        let entry: Data
        if let tokens = segment.tokens {
            var assembling = partial ?? Data(count: shape.byteCount)
            try QwenPhaseSplitSlab.place(bytes, into: &assembling, shape: shape, tokens: tokens)
            guard tokens.upperBound == shape.shape[2] else { partial = assembling; return }
            partial = nil; entry = assembling
        } else { entry = bytes }
        guard sha256(entry) == header.content.entries[segment.entryIndex].sha256 else {
            if refusal == nil {
                refusal = "global layer \(shape.globalLayerIndex) \(shape.component): received bytes differ from the sender's digest"
            }
            return
        }
        verified[segment.entryIndex] = entry
    }

    /// The verified logical bytes of every transferred component, by entry index.
    func finish() throws -> [Int: Data] {
        guard let refusal else {
            guard complete, partial == nil, verified.count == Set(split.segments.map(\.entryIndex)).count else {
                throw ProbeError("Hand-off ended before every agreed segment arrived")
            }
            return verified
        }
        throw ProbeError("Hand-off refused: \(refusal)")
    }
}
