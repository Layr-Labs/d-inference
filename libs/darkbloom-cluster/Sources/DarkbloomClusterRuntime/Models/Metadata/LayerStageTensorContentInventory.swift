import Foundation

/// One source tensor's storage location and the SHA-256 of its stored bytes,
/// `sourceFile[sourceOffset ..< sourceOffset + byteCount]`. Metadata only: a
/// record proves nothing about any bytes until a reader hashes them against it.
struct LayerStageTensorContentRecord: Equatable {
    let source: LayerStageSourceTensor
    let contentSHA256: String

    init(source: LayerStageSourceTensor, contentSHA256: String) throws {
        guard QwenDenseProfileIdentity.isSHA256(contentSHA256) else {
            throw ProbeError("Stage tensor content digest must be a lowercase SHA-256")
        }
        self.source = source; self.contentSHA256 = contentSHA256
    }

    /// The layout identity a profile already pins, then where the bytes are and
    /// what they hash to. No field can contain a separator: names, files and
    /// dtypes are validated against closed alphabets before this is called.
    fileprivate var line: String {
        [source.layout.identity, source.sourceFile, String(source.sourceOffset), contentSHA256]
            .joined(separator: "|")
    }

    fileprivate init(line: Data) throws {
        let fields = line.split(separator: UInt8(ascii: "|"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 7 else { throw ProbeError("Stage content inventory line must have seven fields") }
        let shape = try fields[2].split(separator: ",", omittingEmptySubsequences: false)
            .map { try LayerStageTensorContentInventory.integer(String($0)) }
        let layout = try LayerStageTensorLayout(canonicalName: fields[0], shape: shape, sourceDType: fields[1],
            byteCount: LayerStageTensorContentInventory.integer(fields[3]))
        try self.init(source: LayerStageSourceTensor(layout: layout, sourceFile: fields[4],
            sourceOffset: LayerStageTensorContentInventory.integer(fields[5])), contentSHA256: fields[6])
    }
}

/// A model's complete per-tensor content inventory. One SHA-256 over its
/// canonical encoding fixes every name, shape, dtype, byte count, file, offset
/// and content digest, so a registered specification can pin a whole artifact's
/// tensors with a single value. Model-independent, and metadata only.
///
/// The encoding is a schema line, the record count, then one line per record:
/// `name|dtype|shape|byteCount|file|offset|contentSHA256`. Every value has one
/// spelling and records have one order, so equal inventories encode to equal
/// bytes and a decoded document re-encodes to the bytes it was read from.
struct LayerStageTensorContentInventory: Equatable {
    static let schema = "layer-stage-tensor-content-inventory-v1"
    static let maximumTensorCount = 4096
    static let maximumSourceFileCount = 32
    /// Above the longest encoding `maximumTensorCount` valid records can have.
    static let maximumEncodedBytes = 4 * 1024 * 1024

    /// Canonical order: source files ascending by name, then ascending offsets.
    let records: [LayerStageTensorContentRecord]
    let payloadBytes: Int

    init(records: [LayerStageTensorContentRecord]) throws {
        guard (1...Self.maximumTensorCount).contains(records.count) else {
            throw ProbeError("Stage content inventory is empty or exceeds its tensor limit")
        }
        guard Set(records.map { $0.source.layout.canonicalName }).count == records.count else {
            throw ProbeError("Stage content inventory repeats a tensor name")
        }
        var fileCount = 1
        for (previous, next) in zip(records, records.dropFirst()) {
            if previous.source.sourceFile == next.source.sourceFile {
                // Each record's own end was checked against overflow when it was built.
                guard previous.source.sourceOffset + previous.source.layout.byteCount <= next.source.sourceOffset else {
                    throw ProbeError("Stage content inventory ranges overlap or are out of order within a file")
                }
            } else {
                guard previous.source.sourceFile.utf8.lexicographicallyPrecedes(next.source.sourceFile.utf8) else {
                    throw ProbeError("Stage content inventory files are out of order")
                }
                fileCount += 1
            }
        }
        guard fileCount <= Self.maximumSourceFileCount else {
            throw ProbeError("Stage content inventory exceeds its source file limit")
        }
        self.records = records
        payloadBytes = try QwenLongPrefillCheckedBytes.sum(records.map { $0.source.layout.byteCount })
    }

    func encoded() -> Data {
        Data(([Self.schema, String(records.count)] + records.map(\.line)).map { $0 + "\n" }.joined().utf8)
    }

    /// The value a registered specification pins.
    var encodedSHA256: String { sha256(encoded()) }

    /// Refuses everything but a canonical encoding. Field alphabets, tensor
    /// geometry and source locations are checked by the record types; this
    /// checks the framing, and the initializer above checks names and ranges.
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw ProbeError("Stage content inventory exceeds its encoded byte limit")
        }
        let newline = UInt8(ascii: "\n")
        guard data.last == newline else {
            throw ProbeError("Stage content inventory does not end with a newline")
        }
        // Every line ends with one newline, so nothing follows the last record.
        let lines = data.dropLast().split(separator: newline, omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0].elementsEqual(schema.utf8) else {
            throw ProbeError("Stage content inventory has an unknown schema or no record count")
        }
        guard try integer(String(decoding: lines[1], as: UTF8.self)) == lines.count - 2 else {
            throw ProbeError("Stage content inventory is truncated or has trailing data")
        }
        return try Self(records: lines.dropFirst(2).map(LayerStageTensorContentRecord.init(line:)))
    }

    /// Dropping file, offset and content leaves the layout inventory a
    /// registered profile already pins: identity lines in canonical-name order.
    var layoutInventorySHA256: String {
        QwenDenseProfileIdentity.fingerprint(records.map { $0.source.layout }
            .sorted { $0.canonicalName < $1.canonicalName }.map(\.identity))
    }

    /// Decimal integers have exactly one accepted spelling.
    fileprivate static func integer(_ field: String) throws -> Int {
        guard let value = Int(field), String(value) == field else {
            throw ProbeError("Stage content inventory integers must be canonical decimals")
        }
        return value
    }
}
