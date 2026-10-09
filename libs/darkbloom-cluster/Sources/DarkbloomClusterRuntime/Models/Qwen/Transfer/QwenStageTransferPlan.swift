import Foundation

/// The two constants both ranks agree on before a stage is transferred.
struct QwenStageTransferLimits: Encodable, Equatable {
    /// `CollectivePointToPointShape.hardByteLimit`: the most one receive may
    /// allocate before a byte of it is validated. No piece exceeds it.
    static let hardPieceByteLimit = 16 * 1024 * 1024
    /// Refusal bounds for a window, well above the proposal below.
    static let hardWindowByteLimit = 1024 * 1024 * 1024
    static let hardWindowPieceLimit = 1024
    /// The design's proposal. The two-Mac stream probe settles the final sizes.
    static let proposed = Self(pieceBytes: 8 * 1024 * 1024, windowBytes: 64 * 1024 * 1024, windowPieces: 64)

    /// Largest message. A tensor above it is split into row-aligned pieces.
    let pieceByteLimit: Int
    /// A window is the longest run of pieces within both of these limits.
    let windowByteLimit: Int
    let windowPieceLimit: Int

    init(pieceByteLimit: Int, windowByteLimit: Int, windowPieceLimit: Int) throws {
        guard (1...Self.hardPieceByteLimit).contains(pieceByteLimit),
              (pieceByteLimit...Self.hardWindowByteLimit).contains(windowByteLimit),
              (1...Self.hardWindowPieceLimit).contains(windowPieceLimit) else {
            throw ProbeError("Stage transfer piece or window limit is outside its bounds")
        }
        self.init(pieceBytes: pieceByteLimit, windowBytes: windowByteLimit, windowPieces: windowPieceLimit)
    }

    private init(pieceBytes: Int, windowBytes: Int, windowPieces: Int) {
        pieceByteLimit = pieceBytes; windowByteLimit = windowBytes; windowPieceLimit = windowPieces
    }
}

/// The framing of a stage transfer. Both ranks compute it from the delivered
/// stages' ordered active inventories and the agreed limits, so no message
/// carries a name, shape, dtype or size: the receiver already knows each one.
/// Metadata only; it reads no file and holds no tensor.
struct QwenStageTransferPlan: Equatable {
    /// One stage the receiving rank will hold, with `inventory.active` in its
    /// own order. A rank that holds both stages is delivered both.
    struct DeliveredStage {
        let stageIndex: Int
        let active: [QwenStageActiveTensor]
    }

    struct Tensor: Equatable {
        let stageIndex: Int
        let sourceName: String
        let localName: String
        let shape: [Int]
        let dtype: QwenStageStoredDType
        let byteCount: Int
        /// Consecutive pieces, in axis-0 order.
        let pieces: Range<Int>
    }

    /// One message: a whole tensor with its real shape, or a run of leading
    /// rows of a tensor above the piece limit.
    struct Piece: Equatable {
        let index: Int
        let tensor: Int
        /// Where this piece starts within its tensor's stored bytes.
        let byteOffset: Int
        let byteCount: Int
        let shape: [Int]
        let dtype: QwenStageStoredDType
    }

    struct Window: Equatable {
        let pieces: Range<Int>
        /// Payload bytes of every earlier window.
        let precedingBytes: Int
        let byteCount: Int
    }

    /// Five seconds plus one millisecond per megabyte, which is one nanosecond
    /// per byte. A duration, because the two ranks' uptime clocks differ.
    static let budgetBaseNanoseconds: UInt64 = 5_000_000_000
    /// At the proposed piece size this is half a terabyte of payload.
    static let maximumPieceCount = 65_536

    let limits: QwenStageTransferLimits
    let tensors: [Tensor]
    let pieces: [Piece]
    let windows: [Window]
    let payloadBytes: Int
    let budgetNanoseconds: UInt64
    let fingerprint: String

    init(stages: [DeliveredStage], limits: QwenStageTransferLimits) throws {
        guard !stages.isEmpty, stages.allSatisfy({ (0...1).contains($0.stageIndex) }),
              zip(stages, stages.dropFirst()).allSatisfy({ $0.stageIndex < $1.stageIndex }) else {
            throw ProbeError("Stage transfer delivers one or both stages, each once, in stage order")
        }
        guard stages.reduce(0, { $0 + $1.active.count }) <= LayerStageTensorContentInventory.maximumTensorCount else {
            throw ProbeError("Stage transfer exceeds its tensor limit")
        }
        var tensors: [Tensor] = [], pieces: [Piece] = []
        for stage in stages {
            guard !stage.active.isEmpty,
                  Set(stage.active.map(\.localName)).count == stage.active.count else {
                throw ProbeError("Stage transfer active inventory is empty or repeats a local name")
            }
            for entry in stage.active {
                guard let dtype = QwenStageStoredDType(nativeName: entry.sourceDType),
                      (1...4).contains(entry.shape.count),
                      entry.shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }),
                      entry.byteCount == (try QwenLongPrefillCheckedBytes.product(entry.shape + [dtype.elementBytes])) else {
                    throw ProbeError("Stage transfer tensor has an unsupported dtype, shape or byte count: \(entry.sourceName)")
                }
                let first = pieces.count, rowBytes = entry.byteCount / entry.shape[0]
                let split = try RowSplit(rows: entry.shape[0], rowBytes: rowBytes, pieceByteLimit: limits.pieceByteLimit)
                guard split.pieceCount <= Self.maximumPieceCount - first else {
                    throw ProbeError("Stage transfer exceeds its piece limit")
                }
                var offset = 0
                for ordinal in 0..<split.pieceCount {
                    let rows = split.rows(ordinal)
                    pieces.append(Piece(index: pieces.count, tensor: tensors.count, byteOffset: offset,
                        byteCount: rows * rowBytes, shape: [rows] + entry.shape.dropFirst(), dtype: dtype))
                    offset += rows * rowBytes
                }
                tensors.append(Tensor(stageIndex: stage.stageIndex, sourceName: entry.sourceName,
                    localName: entry.localName, shape: entry.shape, dtype: dtype, byteCount: entry.byteCount,
                    pieces: first..<pieces.count))
            }
        }
        guard Set(tensors.map(\.sourceName)).count == tensors.count else {
            throw ProbeError("Stage transfer delivers a source tensor twice")
        }
        payloadBytes = try QwenLongPrefillCheckedBytes.sum(tensors.map(\.byteCount))
        var windows: [Window] = [], start = 0, bytes = 0, preceding = 0
        for piece in pieces {
            if piece.index - start == limits.windowPieceLimit || bytes + piece.byteCount > limits.windowByteLimit {
                windows.append(Window(pieces: start..<piece.index, precedingBytes: preceding, byteCount: bytes))
                preceding += bytes; start = piece.index; bytes = 0
            }
            bytes += piece.byteCount
        }
        windows.append(Window(pieces: start..<pieces.count, precedingBytes: preceding, byteCount: bytes))
        self.limits = limits; self.tensors = tensors; self.pieces = pieces; self.windows = windows
        budgetNanoseconds = Self.budgetBaseNanoseconds + UInt64(payloadBytes)
        struct Identity: Encodable {
            struct Stage: Encodable {
                let stageIndex: Int
                /// `QwenStageStorageSummary.activeMappingSHA256` of the same stage.
                let activeMappingSHA256: String
            }
            let schema = "qwen_stage_transfer_plan_v1"
            let limits: QwenStageTransferLimits
            let stages: [Stage]
            let tensorCount: Int, pieceCount: Int, windowCount: Int, payloadBytes: Int
            let budgetNanoseconds: UInt64
        }
        fingerprint = sha256(try canonicalJSONData(Identity(limits: limits,
            stages: stages.map { .init(stageIndex: $0.stageIndex, activeMappingSHA256: sha256(try canonicalJSONData($0.active))) },
            tensorCount: tensors.count, pieceCount: pieces.count, windowCount: windows.count,
            payloadBytes: payloadBytes, budgetNanoseconds: budgetNanoseconds)))
    }

    /// How a tensor is cut along axis 0. A tensor within the limit is one
    /// piece. A larger one takes the fewest pieces the limit allows, as equal
    /// as whole rows permit: row counts differ by at most one, larger first.
    struct RowSplit: Equatable {
        let pieceCount: Int
        let smallerRows: Int
        let largerPieceCount: Int

        init(rows: Int, rowBytes: Int, pieceByteLimit: Int) throws {
            guard rowBytes <= pieceByteLimit else {
                throw ProbeError("Stage transfer cannot split a tensor whose single row exceeds the piece limit")
            }
            pieceCount = (rows - 1) / (pieceByteLimit / rowBytes) + 1
            smallerRows = rows / pieceCount; largerPieceCount = rows % pieceCount
        }

        func rows(_ ordinal: Int) -> Int { smallerRows + (ordinal < largerPieceCount ? 1 : 0) }
    }
}
