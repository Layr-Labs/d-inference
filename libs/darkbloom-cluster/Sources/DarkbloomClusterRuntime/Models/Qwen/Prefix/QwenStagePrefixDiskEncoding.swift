import Foundation
import MLX
@_spi(Darkbloom) import MLXLMCommon

/// Which attention rows of a family's prompt-prefix records may be stored
/// encoded. The one place that decides it (`QwenStagePrefixDiskEncoding.rows`
/// asks only this, the layers its tier keeps native and the codec's own
/// geometry check). A record keeps recurrent, convolution and
/// speculative-history state native whatever the family; only the
/// `attention` slots (`keys`, `values`) can be encoded.
public enum QwenStagePrefixDiskFamily: String, Sendable, Equatable, CaseIterable {
    /// Qwen 3.5-family full-attention keys and values, both slots (the 9B,
    /// 27B and 35B A3B rows and the Bonsai packs that share their attention,
    /// under the pipeline and tensor parallel alike).
    case qwenAttention = "qwen-attention"
    /// GLM-5.3-Flash's DSA layers: the latents (the `keys` slot, read by the
    /// absorbed attention as its keys) when the codec encodes their width. The
    /// index keys and pool gates (the `values` slot) select each query's top-k
    /// history rows; an approximate index key can select another row, so they
    /// stay native. A NextN history a record keeps as an attention entry is
    /// speculative state: its tier names that layer native
    /// (`QwenStagePrefixDiskEncoding.nativeLayers`).
    case glm5NextDSA = "glm5-next-dsa"
    /// Every row native: the families whose records are not qualified encoded
    /// (MiMo, which the single-Mac product also keeps native, Gemma 4 and
    /// Nemotron), and the default of every tier that names no family.
    case native

    /// Whether this family's attention slot (`keys` or `values`) may be encoded.
    func encodes(slot kind: String) -> Bool {
        switch self {
        case .qwenAttention: kind == "keys" || kind == "values"
        case .glm5NextDSA: kind == "keys"
        case .native: false
        }
    }

    /// The family of a row the layer-stage runtime (`QwenResidentRuntime`)
    /// serves: the Qwen 3.5-family rows' attention; Nemotron and Gemma 4 keep
    /// native records.
    static func layerStage(runtimeModelID: String) -> Self {
        guard let model = QwenRegisteredDenseModel(rawValue: runtimeModelID), model != .nemotron35Lightning else { return .native }
        return .qwenAttention
    }
}

/// How one SSD tier stores attention rows: the single-Mac checkpoint profile
/// (`PagedKVQuantizationSelection`, default `balanced`: 4-bit keys and values,
/// affine groups of 64 with FP32 scale and offset, keys in a normalized signed
/// Hadamard basis, the newest 128 rows exact) applied to the slots its family
/// allows, through the SDK's own row codec (`CBv2CheckpointRowCodec`, the
/// bytes main's complete checkpoints store for the same row).
///
/// A record's newest `recentTokenCount` rows (of each encoded entry) are
/// native, the older ones encoded; restore decodes into native arrays of the
/// shapes a native record gives, so adoption is unchanged. Restored older
/// rows are approximate: a request restored from an encoded record is not
/// byte-equal to the same request computed from zero. `native` keeps every
/// row exact (the byte-exact option).
///
/// Bound three ways: into the plan directory (`planScopeSuffix`; records of
/// another encoding live in another directory and are never offered), into
/// every record's sealed header (`header`; a record of another encoding is
/// refused and deleted), and into the pair's load agreement
/// (`loadAgreementFields`; peers told different encodings stop at the first
/// exchange). An encoding that encodes nothing (native, or a family with no
/// eligible slot) adds nothing to any of the three, so its directories,
/// headers and agreements keep the bytes they always had.
public struct QwenStagePrefixDiskEncoding: Equatable, Sendable, CustomStringConvertible {
    /// The rank's wire switch: the name its owner resolved from the product's
    /// checkpoint precision (`engine_v2_kv_checkpoint_quantization`).
    public static let environmentName = "DARKBLOOM_CLUSTER_PREFIX_SSD_QUANTIZATION"

    /// What the owner asked for; `configuration` says what applies.
    public let quantization: PagedKVQuantizationSelection
    public let family: QwenStagePrefixDiskFamily
    /// Layers whose attention entries stay native whatever the family: a
    /// speculative head's history that a record keeps as an attention entry
    /// (GLM-5.3-Flash's NextN layer under tensor parallel), because
    /// speculative state is never encoded. The model and the build fix it,
    /// and both name the tier's directory, so it binds nothing itself; a
    /// record whose entries were encoded under another set is refused at
    /// restore (`QwenStagePrefixDiskRestoreWork`).
    public let nativeLayers: Set<Int>

    public static let native = Self(quantization: .native, family: .native)

    public init(quantization: PagedKVQuantizationSelection, family: QwenStagePrefixDiskFamily, nativeLayers: Set<Int> = []) {
        self.quantization = quantization
        self.family = family
        self.nativeLayers = nativeLayers
    }

    /// This encoding with `layers` kept native too.
    public func keepingNative(layers: some Sequence<Int>) -> Self {
        .init(quantization: quantization, family: family, nativeLayers: nativeLayers.union(layers))
    }

    /// This rank's encoding for `family`, from its launch environment, as main
    /// parses a checkpoint precision (`balanced`, `k8v4`, `k8v8`, `native` and
    /// their aliases; empty or absent is `balanced`). Anything else stops the
    /// load by name.
    public static func fromEnvironment(_ environment: [String: String], family: QwenStagePrefixDiskFamily) throws -> Self {
        let raw = environment[environmentName] ?? ""
        do {
            return .init(quantization: try PagedKVQuantizationPolicy.parseSelection(raw, purpose: .checkpoint), family: family)
        } catch {
            throw ProbeError("\(environmentName)=\(raw.prefix(32)) is not a checkpoint precision; expected balanced, k8v4, k8v8 or native")
        }
    }

    /// The profile when some slot of this family may be encoded; nil keeps
    /// every row native.
    public var configuration: PagedKVQuantizationConfig? {
        family == .native ? nil : quantization.configuration
    }

    /// The layout of one attention entry (`slot` of `layer`, a `[1, heads,
    /// committed, width]` array of `dtype`, or the same rows read from a
    /// history), or nil when it stays native. Encoded: a slot the family
    /// encodes of a layer not kept native, an FP16, BF16 or FP32 row, and a
    /// width the format encodes (a multiple of the group size, at most 512).
    func rows(layer: Int, slot kind: String, width: Int, dtype: DType, committed: Int) -> QwenStagePrefixDiskEncodedRows? {
        guard let configuration, family.encodes(slot: kind), !nativeLayers.contains(layer), committed > 0 else { return nil }
        return try? QwenStagePrefixDiskEncodedRows(configuration: configuration, dtype: dtype, width: width,
            values: kind == "values", nativeFrom: max(0, committed - configuration.recentTokenCount))
    }

    /// Sealed in every record written under this encoding; nil when it
    /// encodes nothing.
    var header: QwenStagePrefixDiskHeader.Encoding? {
        configuration.map { .init(quantization: quantization.rawValue, identity: $0.identity, family: family.rawValue) }
    }

    /// Appended to the plan scope that names the tier's directory.
    var planScopeSuffix: String {
        header.map { "|records=" + [$0.quantization, $0.identity, $0.family].joined(separator: ":") } ?? ""
    }

    /// Both ranks bind these, so a pair whose ranks would write and read
    /// records differently refuses to load.
    public var loadAgreementFields: [String] {
        header.map { ["cluster-prefix-ssd-records-v1", $0.quantization, $0.identity, $0.family] } ?? []
    }

    /// For log lines: the selection that applies.
    public var description: String { configuration == nil ? "native" : quantization.rawValue }
}

/// One encoded attention entry's rows. A record stores an entry in units of
/// `blockTokens` rows, all heads of a unit together; within a unit each head
/// keeps its rows in order, those below `nativeFrom` encoded
/// (`encodedRowBytes` each) and the rest native (`nativeRowBytes`, the bytes
/// as captured). `nativeFrom` is the record's committed length less the
/// profile's recent count, so the newest rows of the record are its exact
/// band; a shallower frontier on the record's grid reads its rows
/// `[0, frontier)`, approximate below `nativeFrom` and exact from it.
struct QwenStagePrefixDiskEncodedRows: Equatable {
    let configuration: PagedKVQuantizationConfig
    let dtype: DType
    let width: Int
    /// The value role (no rotation); keys are rotated as the profile says.
    let values: Bool
    let nativeFrom: Int
    let nativeRowBytes: Int
    let encodedRowBytes: Int

    init(configuration: PagedKVQuantizationConfig, dtype: DType, width: Int, values: Bool, nativeFrom: Int) throws {
        guard [.float16, .bfloat16, .float32].contains(dtype), nativeFrom >= 0 else {
            throw ProbeError("Prefix record rows of \(dtype) are not encodable")
        }
        let layout = try configuration.rowLayout(headDim: width)
        self.configuration = configuration; self.dtype = dtype; self.width = width; self.values = values
        self.nativeFrom = nativeFrom
        nativeRowBytes = width * dtype.size
        encodedRowBytes = values ? layout.valueRowBytes : layout.keyRowBytes
    }

    /// How many of the rows `[first, first + rows)` are encoded.
    func encodedCount(first: Int, rows: Int) -> Int { max(0, min(rows, nativeFrom - first)) }

    /// Plaintext bytes of one head's rows `[first, first + rows)`.
    func headBytes(first: Int, rows: Int) -> Int {
        let encoded = encodedCount(first: first, rows: rows)
        return encoded * encodedRowBytes + (rows - encoded) * nativeRowBytes
    }

    private func codec() throws -> CBv2CheckpointRowCodec {
        let codec = try CBv2CheckpointRowCodec(dtype: dtype, width: width, values: values, quantization: configuration)
        guard codec.nativeRowBytes == nativeRowBytes, codec.encodedRowBytes == encodedRowBytes else {
            throw ProbeError("Prefix record row codec differs from its layout")
        }
        return codec
    }

    /// One unit's plaintext: every head's rows `[first, first + rows)` of
    /// `source`, the entry's native bytes (`[heads, committed, width]`, row
    /// major). Throws for a row the codec refuses (non-finite, or one whose
    /// reconstruction leaves the native dtype): such a record is not written.
    func encode(source: UnsafeRawBufferPointer, heads: Int, committed: Int, first: Int, rows: Int) throws -> Data {
        guard source.count == heads * committed * nativeRowBytes, first >= 0, rows > 0, first + rows <= committed else {
            throw ProbeError("Prefix record unit lies outside its source")
        }
        return try encode(heads: heads, first: first, rows: rows) {
            source.baseAddress!.advanced(by: ($0 * committed + first) * nativeRowBytes)
        }
    }

    /// The same plaintext from `unit`, the unit's own native rows
    /// (`[heads, rows, width]`, rows `[first, first + rows)` of each head):
    /// for an entry whose writer reads each unit's rows from a history
    /// instead of slicing a whole array. The bytes equal `encode(source:...)`'s.
    func encode(unit: UnsafeRawBufferPointer, heads: Int, first: Int, rows: Int) throws -> Data {
        guard unit.count == heads * rows * nativeRowBytes, first >= 0, rows > 0 else {
            throw ProbeError("Prefix record unit lies outside its source")
        }
        return try encode(heads: heads, first: first, rows: rows) { unit.baseAddress!.advanced(by: $0 * rows * nativeRowBytes) }
    }

    /// Each head's rows lie one after another from `start(head)`: those below
    /// `nativeFrom` through the codec, the rest copied.
    private func encode(heads: Int, first: Int, rows: Int, start: (Int) -> UnsafeRawPointer) throws -> Data {
        let encoded = encodedCount(first: first, rows: rows), run = headBytes(first: first, rows: rows)
        let codec = encoded > 0 ? try codec() : nil
        var plaintext = Data(count: heads * run)
        try plaintext.withUnsafeMutableBytes { target in
            for head in 0..<heads {
                let native = start(head)
                var cursor = head * run
                for row in 0 ..< encoded {
                    let bytes = try codec!.encode(UnsafeRawBufferPointer(start: native.advanced(by: row * nativeRowBytes),
                        count: nativeRowBytes))
                    guard bytes.count == encodedRowBytes else { throw ProbeError("Prefix record encoded row size differs") }
                    bytes.withUnsafeBytes { target.baseAddress!.advanced(by: cursor).copyMemory(from: $0.baseAddress!, byteCount: encodedRowBytes) }
                    cursor += encodedRowBytes
                }
                let exact = (rows - encoded) * nativeRowBytes
                if exact > 0 {
                    target.baseAddress!.advanced(by: cursor).copyMemory(from: native.advanced(by: encoded * nativeRowBytes),
                        byteCount: exact)
                }
            }
        }
        return plaintext
    }

    /// One unit's plaintext decoded into `target`, native rows of
    /// `[heads, frontier, width]`: the encoded rows through the canonical
    /// decoder, the band copied byte for byte. Throws for a plaintext of the
    /// wrong size or a row the decoder refuses (malformed coefficients, a
    /// reconstruction outside the dtype).
    func decode(_ plaintext: UnsafeRawBufferPointer, into target: UnsafeMutableRawPointer, heads: Int, frontier: Int,
                first: Int, rows: Int) throws {
        let encoded = encodedCount(first: first, rows: rows), run = headBytes(first: first, rows: rows)
        guard plaintext.count == heads * run, first >= 0, rows > 0, first + rows <= frontier else {
            throw ProbeError("Prefix record unit size differs")
        }
        let codec = encoded > 0 ? try codec() : nil
        for head in 0..<heads {
            var cursor = head * run
            for row in first ..< first + encoded {
                let native = try codec!.decode(UnsafeRawBufferPointer(rebasing: plaintext[cursor ..< cursor + encodedRowBytes]))
                guard native.count == nativeRowBytes else { throw ProbeError("Prefix record decoded row size differs") }
                native.withUnsafeBytes {
                    target.advanced(by: (head * frontier + row) * nativeRowBytes).copyMemory(from: $0.baseAddress!, byteCount: nativeRowBytes)
                }
                cursor += encodedRowBytes
            }
            let exact = (rows - encoded) * nativeRowBytes
            if exact > 0 {
                target.advanced(by: (head * frontier + first + encoded) * nativeRowBytes)
                    .copyMemory(from: plaintext.baseAddress!.advanced(by: cursor), byteCount: exact)
            }
        }
    }
}
