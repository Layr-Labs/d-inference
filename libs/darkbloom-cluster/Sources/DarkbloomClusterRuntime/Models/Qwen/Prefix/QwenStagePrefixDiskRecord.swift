import Cmlx
import CryptoKit
import Darwin
import Foundation
import MLX

/// Keys derived from the owner's SSD key: one encrypts each record's own
/// random data key, one names records so a file name reveals no prompt digest.
struct QwenStagePrefixDiskKeys {
    let encryption: SymmetricKey
    let naming: SymmetricKey

    init(master: Data) {
        let input = SymmetricKey(data: master)
        let salt = Data("darkbloom-cluster-prefix-ssd-v1".utf8)
        encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("encryption".utf8), outputByteCount: 32)
        naming = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("naming".utf8), outputByteCount: 32)
    }

    func tag(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: naming).map { String(format: "%02x", $0) }.joined()
    }

    /// The record's file name: 32 hex characters of a keyed tag of its key.
    func fileName(recordKey: String) -> String { String(tag("record|" + recordKey).prefix(32)) + ".dbpx" }

    /// Written once per rank directory: a different key wipes the directory.
    var keyCheck: String { tag("key-check") }
}

/// What one record holds, sealed inside it. Attention arrays are this rank's
/// rows `[1, heads, tokens, headDim]` up to `committedTokens`, stored in
/// units of `blockTokens` rows (all heads of one block per unit), so a
/// shallower frontier on the block grid reads only its own units. Recurrent
/// arrays are whole, one unit each, per kept frontier.
struct QwenStagePrefixDiskHeader: Codable, Equatable {
    struct Frontier: Codable, Equatable { let tokens: Int; let key: String }
    struct Unit: Codable, Equatable { let index: Int; let offset: Int; let length: Int }
    struct Attention: Codable, Equatable {
        let layer: Int
        let kind: String
        let dtype: String
        let heads: Int
        let headDim: Int
        let units: [Unit]
    }
    struct Recurrent: Codable, Equatable {
        let frontier: Int
        let layer: Int
        let kind: String
        let dtype: String
        let shape: [Int]
        let unit: Unit
    }
    /// Version 1 stores the speculative history per frontier (`history`);
    /// version 2 stores it once (`sharedHistory`). Both are read.
    static let version = 1
    static let sharedHistoryVersion = 2
    var version: Int
    let scope: String
    let recordKey: String
    let committedTokens: Int
    let blockTokens: Int
    let frontiers: [Frontier]
    let attention: [Attention]
    let recurrent: [Recurrent]
    /// The decoding rank's speculative (MTP) head history at a kept frontier
    /// (PERF-BACKLOG 13; oMLX `51df0333`: the drafter's state travels with the
    /// snapshot): three whole units per frontier, kinds `hidden` (`[1, f-1, H]`),
    /// `tokens` (`[1, f-1]`, int32) and `last` (`[1, 1, H]`). Absent in records
    /// written before this section existed and on the non-decoding rank.
    var history: [Recurrent]? = nil
    /// Version 2: the speculative history stored once (finding storage:S2 /
    /// reads:R6: the history at a shallower frontier is a prefix of the
    /// deepest one's, and version 1 wrote a whole copy per frontier, 10-17% of
    /// a decoding rank's record). Rows `[0, prompt)` of the head's hidden
    /// states (`[1, prompt - 1, H]` followed by the `last` row at `prompt - 1`)
    /// in units of `blockTokens` rows, and the tokens `[1, prompt - 1]` in one
    /// unit; frontier `f` reads rows `[0, f)` and the first `f - 1` tokens.
    var sharedHistory: SharedHistory? = nil
    struct SharedHistory: Codable, Equatable {
        /// The deepest frontier with a history: `prompt` rows are stored.
        let prompt: Int
        let hiddenDType: String
        let hiddenSize: Int
        let hiddenUnits: [Unit]
        let tokensDType: String
        let tokens: Unit
        /// The kept frontiers that carry a history.
        let frontiers: [Int]
    }
    /// The rank that wrote the record, sealed with the header: a record
    /// restores only on that rank (`QwenStagePrefixDiskPolicy.belongs`), not on
    /// another rank of the same plan that shares a root on one Mac.
    var rank: Int? = nil
    let createdUnixSeconds: Double

    var historyEntries: [Recurrent] { history ?? [] }

    /// Bytes of every sealed unit after the header.
    var dataBytes: Int {
        attention.reduce(0) { $0 + $1.units.reduce(0) { $0 + $1.length } } + recurrent.reduce(0) { $0 + $1.unit.length }
            + historyEntries.reduce(0) { $0 + $1.unit.length }
            + (sharedHistory.map { $0.hiddenUnits.reduce(0) { $0 + $1.length } + $0.tokens.length } ?? 0)
    }
}

enum QwenStagePrefixDiskFormat {
    static let magic = Data("DBPXSSD1".utf8)
    static let tagBytes = 16
    static let maximumHeaderBytes = 8 * 1_048_576

    static let dtypes: [String: DType] = ["float16": .float16, "bfloat16": .bfloat16, "float32": .float32,
        "int32": .int32, "uint32": .uint32, "int16": .int16, "uint16": .uint16, "int8": .int8, "uint8": .uint8,
        "int64": .int64, "uint64": .uint64, "bool": .bool]
    static func name(_ dtype: DType) -> String? { dtypes.first(where: { $0.value == dtype })?.key }

    static func unitNonce(_ index: Int) throws -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var value = UInt64(index).littleEndian
        withUnsafeBytes(of: &value) { for i in 0..<8 { bytes[i] = $0[i] } }
        return try AES.GCM.Nonce(data: bytes)
    }
    /// Unit indices never reach this nonce.
    static func headerNonce() throws -> AES.GCM.Nonce { try AES.GCM.Nonce(data: [UInt8](repeating: 0xFF, count: 12)) }
}

/// Bytes of evaluated arrays prepared on the serving thread and written by
/// the background writer. The arrays are kept alive (and unchanged: they are
/// a request's confirmed copies) until the job is done; nothing here calls MLX.
final class QwenStagePrefixDiskJob: @unchecked Sendable {
    struct Source {
        let array: MLXArray
        let data: Data
    }
    let header: QwenStagePrefixDiskHeader
    let fileName: String
    /// Per attention entry, its whole `[1, heads, committed, headDim]` source.
    let attention: [Source]
    /// Per recurrent entry, its source.
    let recurrent: [Source]
    /// Per history entry, its source.
    let history: [Source]
    /// Version 2: the deepest history's hidden rows, its `last` row and its tokens.
    let sharedHidden: Source?
    let sharedLast: Source?
    let sharedTokens: Source?

    init(header: QwenStagePrefixDiskHeader, fileName: String, attention: [Source], recurrent: [Source], history: [Source] = [],
         sharedHidden: Source? = nil, sharedLast: Source? = nil, sharedTokens: Source? = nil) {
        self.header = header; self.fileName = fileName; self.attention = attention; self.recurrent = recurrent
        self.history = history; self.sharedHidden = sharedHidden; self.sharedLast = sharedLast; self.sharedTokens = sharedTokens
    }

    var hostBytes: Int {
        attention.reduce(0) { $0 + $1.data.count } + recurrent.reduce(0) { $0 + $1.data.count }
            + history.reduce(0) { $0 + $1.data.count }
            + [sharedHidden, sharedLast, sharedTokens].reduce(0) { $0 + ($1?.data.count ?? 0) }
    }

    /// Whether every kept frontier's history is a view of the deepest one's
    /// storage: hidden and tokens start where the deepest's do and `last` is
    /// the deepest's row `f - 1` (the decoder's `prefixHistory(at:)` views one
    /// kept copy). Only then is the history stored once; anything else is
    /// stored per frontier, so the bytes restored never change.
    static func sharesHistory(_ histories: [(frontier: Int, history: QwenMTPPrefixHistory)]) -> Bool {
        guard let deepest = histories.max(by: { $0.frontier < $1.frontier })?.history, histories.count > 1 else { return false }
        // Where an evaluated array's first element lives, when its last
        // dimension (and, for hidden rows, the one before) is contiguous.
        func address(_ array: MLXArray, rows: Bool) -> UInt? {
            eval(array)
            let n = array.ndim
            guard n >= 2, let strides = mlx_array_strides(array.ctx), let data = mlx_array_data_uint8(array.ctx) else { return nil }
            guard array.dim(n - 1) <= 1 || Int(strides[n - 1]) == 1 else { return nil }
            if rows, array.dim(n - 2) > 1, Int(strides[n - 2]) != array.dim(n - 1) { return nil }
            return UInt(bitPattern: data)
        }
        let hidden = deepest.hidden, rowBytes = hidden.dim(2) * hidden.dtype.size
        guard let base = address(hidden, rows: true), let tokens = address(deepest.tokens, rows: false) else { return false }
        return histories.allSatisfy { frontier, history in
            if frontier == deepest.frontier { return true }
            guard frontier >= 2, frontier < deepest.frontier, history.hidden.dtype == hidden.dtype,
                  history.tokens.dtype == deepest.tokens.dtype, history.hidden.dim(2) == hidden.dim(2),
                  let h = address(history.hidden, rows: true), let t = address(history.tokens, rows: false),
                  let l = address(history.last, rows: false) else {
                return false
            }
            return h == base && t == tokens && l == base + UInt((frontier - 1) * rowBytes)
        }
    }

    /// Prepares a record of `states` (one prompt's captured frontiers, the
    /// deepest carrying the whole attention copy). Runs on the serving thread:
    /// it evaluates (normally a no-op) and borrows the arrays' bytes.
    static func prepare(scope: String, recordKey: String, fileName: String, rank: Int, deepest: QwenStagePrefixState,
                        frontiers: [(state: QwenStagePrefixState, key: String)], blockTokens: Int) throws -> QwenStagePrefixDiskJob {
        let committed = deepest.committedTokens
        guard committed > 0, blockTokens > 0, !frontiers.isEmpty,
              frontiers.allSatisfy({ $0.state.committedTokens == committed || $0.state.committedTokens % blockTokens == 0 }) else {
            throw ProbeError("Prefix record frontiers are off the block grid")
        }
        eval(deepest.attention.values.flatMap { [$0.keys, $0.values] } + frontiers.flatMap { $0.state.recurrent.values.flatMap { [$0.conv, $0.ssm] } }
            + frontiers.flatMap { $0.state.speculativeHistory.map { [$0.hidden, $0.tokens, $0.last] } ?? [] })
        var index = 0, offset = 0
        func unit(_ plain: Int) -> QwenStagePrefixDiskHeader.Unit {
            defer { index += 1; offset += plain + QwenStagePrefixDiskFormat.tagBytes }
            return .init(index: index, offset: offset, length: plain + QwenStagePrefixDiskFormat.tagBytes)
        }
        var attention: [QwenStagePrefixDiskHeader.Attention] = [], attentionSources: [Source] = []
        for layer in deepest.attention.keys.sorted() {
            let pair = deepest.attention[layer]!
            for (kind, array) in [("keys", pair.keys), ("values", pair.values)] {
                guard array.ndim == 4, array.dim(0) == 1, array.dim(2) == committed,
                      let dtype = QwenStagePrefixDiskFormat.name(array.dtype) else {
                    throw ProbeError("Prefix record attention shape or dtype is not storable")
                }
                let heads = array.dim(1), headDim = array.dim(3), rowBytes = headDim * array.dtype.size
                let blocks = (committed + blockTokens - 1) / blockTokens
                let units = (0..<blocks).map { block in unit(heads * min(blockTokens, committed - block * blockTokens) * rowBytes) }
                attention.append(.init(layer: layer, kind: kind, dtype: dtype, heads: heads, headDim: headDim, units: units))
                let data = array.asData(access: .noCopyIfContiguous)
                guard data.data.count == heads * committed * rowBytes else { throw ProbeError("Prefix record attention bytes differ") }
                attentionSources.append(.init(array: array, data: data.data))
            }
        }
        var recurrent: [QwenStagePrefixDiskHeader.Recurrent] = [], recurrentSources: [Source] = []
        for (state, _) in frontiers.sorted(by: { $0.state.committedTokens < $1.state.committedTokens }) {
            for layer in state.recurrent.keys.sorted() {
                let pair = state.recurrent[layer]!
                for (kind, array) in [("conv", pair.conv), ("ssm", pair.ssm)] {
                    guard let dtype = QwenStagePrefixDiskFormat.name(array.dtype) else {
                        throw ProbeError("Prefix record recurrent dtype is not storable")
                    }
                    let data = array.asData(access: .noCopyIfContiguous)
                    guard data.data.count == array.nbytes else { throw ProbeError("Prefix record recurrent bytes differ") }
                    recurrent.append(.init(frontier: state.committedTokens, layer: layer, kind: kind, dtype: dtype,
                        shape: array.shape, unit: unit(array.nbytes)))
                    recurrentSources.append(.init(array: array, data: data.data))
                }
            }
        }
        // The speculative head's history at each kept frontier that has one
        // (the decoding rank of a speculative pair), after the recurrent units.
        var history: [QwenStagePrefixDiskHeader.Recurrent] = [], historySources: [Source] = []
        var kept: [(frontier: Int, history: QwenMTPPrefixHistory)] = []
        for (state, _) in frontiers.sorted(by: { $0.state.committedTokens < $1.state.committedTokens }) {
            guard let value = state.speculativeHistory else { continue }
            guard value.frontier == state.committedTokens, value.hidden.ndim == 3, value.tokens.ndim == 2, value.last.ndim == 3,
                  value.hidden.dim(1) == value.frontier - 1, value.tokens.dim(1) == value.frontier - 1, value.last.dim(1) == 1,
                  value.last.dim(2) == value.hidden.dim(2), value.last.dtype == value.hidden.dtype else {
                throw ProbeError("Prefix record speculative history does not describe its frontier")
            }
            kept.append((state.committedTokens, value))
        }
        var shared: QwenStagePrefixDiskHeader.SharedHistory?
        var sharedSources: (hidden: Source, last: Source, tokens: Source)?
        if sharesHistory(kept), let deepest = kept.last?.history {
            // Once: rows [0, D) in block units, then the tokens.
            guard let hiddenDType = QwenStagePrefixDiskFormat.name(deepest.hidden.dtype),
                  let tokensDType = QwenStagePrefixDiskFormat.name(deepest.tokens.dtype) else {
                throw ProbeError("Prefix record history dtype is not storable")
            }
            let d = deepest.frontier, rowBytes = deepest.hidden.dim(2) * deepest.hidden.dtype.size
            let units = (0..<((d + blockTokens - 1) / blockTokens)).map { block in
                unit(min(blockTokens, d - block * blockTokens) * rowBytes)
            }
            let hiddenData = deepest.hidden.asData(access: .noCopyIfContiguous).data
            let lastData = deepest.last.asData(access: .noCopyIfContiguous).data
            let tokensData = deepest.tokens.asData(access: .noCopyIfContiguous).data
            guard hiddenData.count == (d - 1) * rowBytes, lastData.count == rowBytes,
                  tokensData.count == deepest.tokens.nbytes else { throw ProbeError("Prefix record history bytes differ") }
            shared = .init(prompt: d, hiddenDType: hiddenDType, hiddenSize: deepest.hidden.dim(2), hiddenUnits: units,
                tokensDType: tokensDType, tokens: unit(tokensData.count), frontiers: kept.map(\.frontier))
            sharedSources = (.init(array: deepest.hidden, data: hiddenData), .init(array: deepest.last, data: lastData),
                .init(array: deepest.tokens, data: tokensData))
            kept = []
        }
        for (frontier, value) in kept {
            for (kind, array) in [("hidden", value.hidden), ("tokens", value.tokens), ("last", value.last)] {
                guard let dtype = QwenStagePrefixDiskFormat.name(array.dtype) else {
                    throw ProbeError("Prefix record history dtype is not storable")
                }
                let data = array.asData(access: .noCopyIfContiguous)
                guard data.data.count == array.nbytes else { throw ProbeError("Prefix record history bytes differ") }
                history.append(.init(frontier: frontier, layer: 0, kind: kind, dtype: dtype,
                    shape: array.shape, unit: unit(array.nbytes)))
                historySources.append(.init(array: array, data: data.data))
            }
        }
        var header = QwenStagePrefixDiskHeader(version: QwenStagePrefixDiskHeader.version, scope: scope, recordKey: recordKey,
            committedTokens: committed, blockTokens: blockTokens,
            frontiers: frontiers.map { .init(tokens: $0.state.committedTokens, key: $0.key) }.sorted { $0.tokens < $1.tokens },
            attention: attention, recurrent: recurrent, createdUnixSeconds: Date().timeIntervalSince1970)
        if !history.isEmpty { header.history = history }
        if let shared { header.sharedHistory = shared; header.version = QwenStagePrefixDiskHeader.sharedHistoryVersion }
        header.rank = rank
        return .init(header: header, fileName: fileName, attention: attentionSources, recurrent: recurrentSources,
            history: historySources, sharedHidden: sharedSources?.hidden, sharedLast: sharedSources?.last,
            sharedTokens: sharedSources?.tokens)
    }

    /// The plaintext of one version-2 history unit: rows
    /// `[block * blockTokens, ...)` of the deepest history's hidden rows
    /// followed by its `last` row.
    func sharedHistoryPlaintext(block: Int) -> Data {
        guard let shared = header.sharedHistory, let hidden = sharedHidden, let last = sharedLast else { return Data() }
        let b = header.blockTokens, rowBytes = last.data.count, d = shared.prompt
        let first = block * b, rows = min(b, d - first)
        var out = Data(count: rows * rowBytes)
        out.withUnsafeMutableBytes { target in
            let hiddenRows = max(0, min(rows, d - 1 - first))
            if hiddenRows > 0 {
                hidden.data.withUnsafeBytes { source in
                    target.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: first * rowBytes), byteCount: hiddenRows * rowBytes)
                }
            }
            if first + rows == d {
                last.data.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: (rows - 1) * rowBytes).copyMemory(from: source.baseAddress!, byteCount: rowBytes)
                }
            }
        }
        return out
    }

    /// The plaintext of one attention unit: all heads of rows
    /// `[block * blockTokens, ...)` from the whole source.
    func attentionPlaintext(entry: Int, block: Int) -> Data {
        let item = header.attention[entry], committed = header.committedTokens, b = header.blockTokens
        let rowBytes = item.headDim * (QwenStagePrefixDiskFormat.dtypes[item.dtype]?.size ?? 0)
        let rows = min(b, committed - block * b), run = rows * rowBytes
        var out = Data(count: item.heads * run)
        attention[entry].data.withUnsafeBytes { source in
            out.withUnsafeMutableBytes { target in
                for head in 0..<item.heads {
                    let from = (head * committed + block * b) * rowBytes
                    target.baseAddress!.advanced(by: head * run).copyMemory(from: source.baseAddress!.advanced(by: from), byteCount: run)
                }
            }
        }
        return out
    }
}

/// Writing and reading one record file. The layout: magic, the record's data
/// key sealed with the owner-derived key, the header sealed with the data
/// key, then every unit sealed with the data key under a nonce made of its
/// index (ciphertext and tag; the nonce is not stored). Any change to a byte
/// fails authentication and the record is treated as absent.
enum QwenStagePrefixDiskIO {
    struct Opened {
        let header: QwenStagePrefixDiskHeader
        let dataStart: Int
        let key: SymmetricKey
        let fileBytes: Int
    }

    static func write(job: QwenStagePrefixDiskJob, keys: QwenStagePrefixDiskKeys, to url: URL,
                      cancelled: () -> Bool) throws -> Int {
        let dek = SymmetricKey(size: .bits256)
        let wrapped = try AES.GCM.seal(dek.withUnsafeBytes { Data($0) }, using: keys.encryption,
            authenticating: QwenStagePrefixDiskFormat.magic).combined!
        let headerBytes = try JSONEncoder().encode(job.header)
        let sealedHeader = try AES.GCM.seal(headerBytes, using: dek, nonce: QwenStagePrefixDiskFormat.headerNonce(),
            authenticating: QwenStagePrefixDiskFormat.magic)
        var preamble = QwenStagePrefixDiskFormat.magic
        func appendLength(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { preamble.append(contentsOf: $0) } }
        appendLength(wrapped.count); preamble.append(wrapped)
        let headerSealed = sealedHeader.ciphertext + sealedHeader.tag
        appendLength(headerSealed.count); preamble.append(headerSealed)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProbeError("Prefix record could not be created (errno \(errno))") }
        var closed = false
        defer { if !closed { close(fd) } }
        _ = fcntl(fd, F_NOCACHE, 1)
        try writeAll(fd, preamble, at: 0)
        let dataStart = preamble.count
        func seal(_ plain: Data, _ unit: QwenStagePrefixDiskHeader.Unit) throws {
            guard !cancelled() else { throw ProbeError("Prefix record write cancelled") }
            let box = try AES.GCM.seal(plain, using: dek, nonce: QwenStagePrefixDiskFormat.unitNonce(unit.index))
            let sealed = box.ciphertext + box.tag
            guard sealed.count == unit.length else { throw ProbeError("Prefix record unit length differs") }
            try writeAll(fd, sealed, at: dataStart + unit.offset)
        }
        for (entry, item) in job.header.attention.enumerated() {
            for (block, unit) in item.units.enumerated() { try seal(job.attentionPlaintext(entry: entry, block: block), unit) }
        }
        for (entry, item) in job.header.recurrent.enumerated() { try seal(job.recurrent[entry].data, item.unit) }
        for (entry, item) in job.header.historyEntries.enumerated() { try seal(job.history[entry].data, item.unit) }
        if let shared = job.header.sharedHistory, let tokens = job.sharedTokens {
            for (block, unit) in shared.hiddenUnits.enumerated() { try seal(job.sharedHistoryPlaintext(block: block), unit) }
            try seal(tokens.data, shared.tokens)
        }
        closed = true
        guard close(fd) == 0 else { throw ProbeError("Prefix record close failed (errno \(errno))") }
        return dataStart + job.header.dataBytes
    }

    static func open(url: URL, keys: QwenStagePrefixDiskKeys) throws -> Opened {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw QwenStagePrefixDiskPolicy.IOFailure("open", code: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ProbeError("Prefix record is not a file") }
        let size = Int(info.st_size)
        let magic = QwenStagePrefixDiskFormat.magic
        let head = try readAll(fd, count: magic.count + 4, at: 0)
        guard head.prefix(magic.count) == magic else { throw ProbeError("Prefix record magic differs") }
        func length(_ data: Data, _ at: Int) -> Int {
            Int(UInt32(littleEndian: data[data.startIndex + at..<data.startIndex + at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
        let wrappedCount = length(head, magic.count)
        guard (28...256).contains(wrappedCount) else { throw ProbeError("Prefix record key length differs") }
        let wrapped = try readAll(fd, count: wrappedCount + 4, at: magic.count + 4)
        let headerCount = length(wrapped, wrappedCount)
        guard (17...QwenStagePrefixDiskFormat.maximumHeaderBytes).contains(headerCount) else {
            throw ProbeError("Prefix record header length differs")
        }
        let dekBytes = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped.prefix(wrappedCount)), using: keys.encryption,
            authenticating: magic)
        let dek = SymmetricKey(data: dekBytes)
        let headerStart = magic.count + 4 + wrappedCount + 4
        let sealedHeader = try readAll(fd, count: headerCount, at: headerStart)
        let box = try AES.GCM.SealedBox(nonce: QwenStagePrefixDiskFormat.headerNonce(),
            ciphertext: sealedHeader.prefix(headerCount - QwenStagePrefixDiskFormat.tagBytes),
            tag: sealedHeader.suffix(QwenStagePrefixDiskFormat.tagBytes))
        let header = try JSONDecoder().decode(QwenStagePrefixDiskHeader.self,
            from: AES.GCM.open(box, using: dek, authenticating: magic))
        let dataStart = headerStart + headerCount
        let versionMatches = header.version == QwenStagePrefixDiskHeader.version ? header.sharedHistory == nil
            : header.version == QwenStagePrefixDiskHeader.sharedHistoryVersion && header.sharedHistory != nil && header.history == nil
        guard versionMatches, header.committedTokens > 0, header.blockTokens > 0,
              dataStart + header.dataBytes == size else {
            throw ProbeError("Prefix record header does not describe its file")
        }
        return .init(header: header, dataStart: dataStart, key: dek, fileBytes: size)
    }

    /// The state at `frontier` (one of the record's frontiers): attention rows
    /// `[0, frontier)` from the units that hold them, and that frontier's
    /// recurrent state. Units are read and opened in parallel, one pass, each
    /// unit read through its page-aligned superset (`readUnit`) and its
    /// plaintext placed in page-aligned buffers that the arrays then own
    /// without a copy (`QwenStagePrefixRestoreBuffer`); arrays are created on
    /// the calling (serving) thread. `stallMilliseconds` (qualification only)
    /// stops halfway, still calling `check`. `readCall` is `pread` (tests
    /// observe the reads).
    static func restore(url: URL, opened: Opened, frontier: Int, stallMilliseconds: Int? = nil,
                        readCall: @escaping ReadCall = { Darwin.pread($0, $1, $2, $3) },
                        check: () throws -> Void) throws -> QwenStagePrefixState {
        let header = opened.header, b = header.blockTokens
        guard frontier > 0, frontier <= header.committedTokens,
              frontier == header.committedTokens || frontier % b == 0,
              header.frontiers.contains(where: { $0.tokens == frontier }) else {
            throw ProbeError("Prefix record does not hold that frontier")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw QwenStagePrefixDiskPolicy.IOFailure("open", code: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let work = try QwenStagePrefixDiskRestoreWork(fd: fd, opened: opened, frontier: frontier, readCall: readCall)
        try check()
        if let stallMilliseconds {
            // Qualification: the first half, a stall (the rank is checked while
            // it waits, as a stalled disk would be), then the rest.
            let halfway = work.total / 2
            DispatchQueue.concurrentPerform(iterations: halfway) { work.run($0) }
            try work.requireNoError()
            log("darkbloom-prefix-ssd-v1 event=qualification-stall ms=\(stallMilliseconds)")
            let end = DispatchTime.now().uptimeNanoseconds + UInt64(stallMilliseconds) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < end { try check(); usleep(20_000) }
            try check()
            DispatchQueue.concurrentPerform(iterations: work.total - halfway) { work.run(halfway + $0) }
        } else {
            DispatchQueue.concurrentPerform(iterations: work.total) { work.run($0) }
        }
        try work.requireNoError()
        try check()
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var pending: [Int: MLXArray] = [:]
        for (entry, item) in header.attention.enumerated() {
            let target = work.targets[entry], dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype]!
            // The array owns the decrypted rows in place (finding R3: the
            // former MLXArray(Data) copied every restored byte once more).
            let array = target.buffer.array([1, item.heads, frontier, item.headDim], dtype: dtype)
            if item.kind == "keys" { pending[item.layer] = array }
            else if item.kind == "values", let keys = pending.removeValue(forKey: item.layer) {
                attention[item.layer] = (keys: keys, values: array)
            } else { throw ProbeError("Prefix record attention entries are not paired") }
        }
        guard pending.isEmpty else { throw ProbeError("Prefix record attention entries are not paired") }
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        var convs: [Int: MLXArray] = [:]
        for (slot, item) in work.recurrentItems.enumerated() {
            guard work.recurrentFilled(slot), let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype] else {
                throw ProbeError("Prefix record recurrent unit missing")
            }
            let array = work.recurrentBuffers[slot].array(item.shape, dtype: dtype)
            if item.kind == "conv" { convs[item.layer] = array }
            else if item.kind == "ssm", let conv = convs.removeValue(forKey: item.layer) {
                recurrent[item.layer] = (conv: conv, ssm: array)
            } else { throw ProbeError("Prefix record recurrent entries are not paired") }
        }
        guard convs.isEmpty else { throw ProbeError("Prefix record recurrent entries are not paired") }
        var historyArrays: [String: MLXArray] = [:]
        for (slot, item) in work.historyItems.enumerated() {
            guard work.historyFilled(slot), let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype] else {
                throw ProbeError("Prefix record history unit missing")
            }
            historyArrays[item.kind] = work.historyBuffers[slot].array(item.shape, dtype: dtype)
        }
        var history: QwenMTPPrefixHistory?
        if let rows = work.sharedRows, let tokens = work.sharedTokensBuffer, let shared = header.sharedHistory {
            guard work.sharedFilled, let hiddenDType = QwenStagePrefixDiskFormat.dtypes[shared.hiddenDType],
                  let tokensDType = QwenStagePrefixDiskFormat.dtypes[shared.tokensDType] else {
                throw ProbeError("Prefix record history unit missing")
            }
            let all = rows.array([1, frontier, shared.hiddenSize], dtype: hiddenDType)
            let allTokens = tokens.array([1, shared.prompt - 1], dtype: tokensDType)
            guard let view = QwenMTPPrefixHistory.view(hidden: all[0..., 0 ..< (frontier - 1), 0...],
                    tokens: allTokens[0..., 0 ..< (frontier - 1)], last: all[0..., (frontier - 1) ..< frontier, 0...],
                    prompt: frontier, frontier: frontier) else {
                throw ProbeError("Prefix record history does not describe its frontier")
            }
            history = view
        } else if !historyArrays.isEmpty {
            guard let hidden = historyArrays["hidden"], let tokens = historyArrays["tokens"], let last = historyArrays["last"],
                  historyArrays.count == 3 else { throw ProbeError("Prefix record history entries are not a triple") }
            guard let view = QwenMTPPrefixHistory.view(hidden: hidden, tokens: tokens, last: last, prompt: frontier, frontier: frontier) else {
                throw ProbeError("Prefix record history does not describe its frontier")
            }
            history = view
        }
        eval(attention.values.flatMap { [$0.keys, $0.values] } + recurrent.values.flatMap { [$0.conv, $0.ssm] }
            + (history.map { [$0.hidden, $0.tokens, $0.last] } ?? []))
        var state = QwenStagePrefixState(committedTokens: frontier, attention: attention, recurrent: recurrent)
        state.speculativeHistory = history
        return state
    }

    typealias ReadCall = (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int

    /// File offsets and buffers of a restore's unit reads are multiples of
    /// this (the page size on Apple silicon).
    static let readAlignment = 16_384

    /// The page-aligned superset `[offset, offset + count)` of the file range
    /// `[start, start + length)`, clipped at the file's end.
    static func alignedExtent(start: Int, length: Int, fileSize: Int) -> (offset: Int, count: Int) {
        let a = readAlignment
        let lower = start / a * a, upper = min(fileSize, (start + length + a - 1) / a * a)
        return (lower, max(0, upper - lower))
    }

    /// One sealed unit, authenticated and decrypted. Read through its
    /// page-aligned superset into a page-aligned scratch buffer (finding R2:
    /// an F_NOCACHE read of more than about 1 MiB at an offset or into a
    /// buffer not 4 KiB aligned left its pages in the unified page cache,
    /// about a quarter of every restored Qwen record).
    static func readUnit(_ fd: Int32, _ unit: QwenStagePrefixDiskHeader.Unit, dataStart: Int, fileSize: Int,
                         key: SymmetricKey, readCall: ReadCall) throws -> Data {
        let start = dataStart + unit.offset
        guard unit.length >= QwenStagePrefixDiskFormat.tagBytes, start >= 0, start + unit.length <= fileSize else {
            throw ProbeError("Prefix record unit lies outside its file")
        }
        let extent = alignedExtent(start: start, length: unit.length, fileSize: fileSize)
        let scratch = try QwenStagePrefixRestoreBuffer(bytes: extent.count)
        var done = 0
        while done < extent.count {
            let n = readCall(fd, scratch.pointer.advanced(by: done), extent.count - done, off_t(extent.offset + done))
            if n < 0 { if errno == EINTR { continue }; throw QwenStagePrefixDiskPolicy.IOFailure("read", code: errno) }
            if n == 0 { throw ProbeError("Prefix record is shorter than its header says") }
            done += n
        }
        let sealed = scratch.pointer.advanced(by: start - extent.offset)
        let cipher = unit.length - QwenStagePrefixDiskFormat.tagBytes
        let box = try AES.GCM.SealedBox(nonce: QwenStagePrefixDiskFormat.unitNonce(unit.index),
            ciphertext: Data(bytesNoCopy: sealed, count: cipher, deallocator: .none),
            tag: Data(bytesNoCopy: sealed.advanced(by: cipher), count: QwenStagePrefixDiskFormat.tagBytes, deallocator: .none))
        return try withExtendedLifetime(scratch) { try AES.GCM.open(box, using: key) }
    }

    static func writeAll(_ fd: Int32, _ data: Data, at offset: Int) throws {
        try data.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = pwrite(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; throw ProbeError("Prefix record write failed (errno \(errno))") }
                done += n
            }
        }
    }

    static func readAll(_ fd: Int32, count: Int, at offset: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let n = pread(fd, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset + done))
                if n < 0 { if errno == EINTR { continue }; throw QwenStagePrefixDiskPolicy.IOFailure("read", code: errno) }
                if n == 0 { throw ProbeError("Prefix record is shorter than its header says") }
                done += n
            }
        }
        return data
    }
}

/// Page-aligned anonymous memory for one restored array (or one unit read):
/// unmapped when released, unless an array took it over (`array`), which then
/// owns it without a copy and unmaps it when MLX frees the array.
final class QwenStagePrefixRestoreBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let bytes: Int
    let mapped: Int
    private var handedOver = false

    init(bytes: Int) throws {
        let a = QwenStagePrefixDiskIO.readAlignment
        let mapped = max(1, (bytes + a - 1) / a) * a
        let allocation = mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard allocation != MAP_FAILED, let allocation, UInt(bitPattern: allocation) % UInt(a) == 0 else {
            if let allocation, allocation != MAP_FAILED { munmap(allocation, mapped) }
            throw ProbeError("Prefix restore buffer could not be allocated")
        }
        pointer = allocation; self.bytes = bytes; self.mapped = mapped
    }

    /// An array over these bytes that owns them from now on (MLX wraps the
    /// page-aligned memory without copying; if it cannot, it copies and
    /// releases them at once). Called once.
    func array(_ shape: [Int], dtype: DType) -> MLXArray {
        precondition(!handedOver, "Prefix restore buffer handed over twice")
        handedOver = true
        let pointer = self.pointer, mapped = self.mapped
        return MLXArray(rawPointer: pointer, shape, dtype: dtype, finalizer: { _ = munmap(pointer, mapped) })
    }

    deinit { if !handedOver { munmap(pointer, mapped) } }
}

/// The parallel part of one restore: every unit is read, authenticated and
/// copied into its place by whichever thread takes it. Output buffers are
/// disjoint per unit; which units finished and the first error are kept
/// under a lock. Nothing here calls MLX.
final class QwenStagePrefixDiskRestoreWork: @unchecked Sendable {
    struct Target { let buffer: QwenStagePrefixRestoreBuffer; let rowBytes: Int; let heads: Int }
    let fd: Int32
    let header: QwenStagePrefixDiskHeader
    let frontier: Int
    let dataStart: Int
    let fileSize: Int
    let key: SymmetricKey
    let readCall: QwenStagePrefixDiskIO.ReadCall
    let targets: [Target]
    let attentionWork: [(entry: Int, block: Int)]
    let recurrentItems: [QwenStagePrefixDiskHeader.Recurrent]
    let historyItems: [QwenStagePrefixDiskHeader.Recurrent]
    let recurrentBuffers: [QwenStagePrefixRestoreBuffer]
    let historyBuffers: [QwenStagePrefixRestoreBuffer]
    /// Version 2: rows `[0, frontier)` of the shared history and its tokens,
    /// nil when the record has none for this frontier.
    let sharedRows: QwenStagePrefixRestoreBuffer?
    let sharedTokensBuffer: QwenStagePrefixRestoreBuffer?
    let sharedBlocks: Int
    private let lock = NSLock()
    private var recurrentDone: [Bool]
    private var historyDone: [Bool]
    private var sharedDone = 0
    private var firstError: Error?

    var total: Int { attentionWork.count + recurrentItems.count + historyItems.count + (sharedRows == nil ? 0 : sharedBlocks + 1) }
    var sharedFilled: Bool { lock.withLock { sharedRows != nil && sharedDone == sharedBlocks + 1 } }

    init(fd: Int32, opened: QwenStagePrefixDiskIO.Opened, frontier: Int,
         readCall: @escaping QwenStagePrefixDiskIO.ReadCall = { Darwin.pread($0, $1, $2, $3) }) throws {
        let header = opened.header, b = header.blockTokens
        self.fd = fd; self.header = header; self.frontier = frontier; self.readCall = readCall
        dataStart = opened.dataStart; fileSize = opened.fileBytes; key = opened.key
        var targets: [Target] = []
        for item in header.attention {
            guard let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype], item.units.count == (header.committedTokens + b - 1) / b,
                  item.heads > 0, item.headDim > 0 else {
                throw ProbeError("Prefix record attention entry is malformed")
            }
            let rowBytes = item.headDim * dtype.size, bytes = item.heads * frontier * rowBytes
            targets.append(.init(buffer: try QwenStagePrefixRestoreBuffer(bytes: bytes), rowBytes: rowBytes, heads: item.heads))
        }
        self.targets = targets
        let blocks = (frontier + b - 1) / b
        attentionWork = header.attention.indices.flatMap { entry in (0..<blocks).map { (entry: entry, block: $0) } }
        recurrentItems = header.recurrent.filter { $0.frontier == frontier }
        historyItems = header.historyEntries.filter { $0.frontier == frontier }
        guard !recurrentItems.isEmpty || header.recurrent.isEmpty else {
            throw ProbeError("Prefix record lacks the frontier's recurrent state")
        }
        func buffer(_ item: QwenStagePrefixDiskHeader.Recurrent) throws -> QwenStagePrefixRestoreBuffer {
            guard let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype], item.shape.allSatisfy({ $0 >= 0 }),
                  item.unit.length == item.shape.reduce(1, *) * dtype.size + QwenStagePrefixDiskFormat.tagBytes else {
                throw ProbeError("Prefix record recurrent or history unit size differs")
            }
            return try QwenStagePrefixRestoreBuffer(bytes: item.unit.length - QwenStagePrefixDiskFormat.tagBytes)
        }
        recurrentBuffers = try recurrentItems.map(buffer)
        historyBuffers = try historyItems.map(buffer)
        if let shared = header.sharedHistory, shared.frontiers.contains(frontier) {
            guard let dtype = QwenStagePrefixDiskFormat.dtypes[shared.hiddenDType],
                  let tokens = QwenStagePrefixDiskFormat.dtypes[shared.tokensDType], shared.hiddenSize > 0,
                  frontier >= 2, frontier <= shared.prompt, shared.prompt <= header.committedTokens,
                  shared.hiddenUnits.count == (shared.prompt + b - 1) / b,
                  shared.tokens.length == (shared.prompt - 1) * tokens.size + QwenStagePrefixDiskFormat.tagBytes else {
                throw ProbeError("Prefix record shared history is malformed")
            }
            let rowBytes = shared.hiddenSize * dtype.size
            for (block, unit) in shared.hiddenUnits.enumerated()
            where unit.length != min(b, shared.prompt - block * b) * rowBytes + QwenStagePrefixDiskFormat.tagBytes {
                throw ProbeError("Prefix record shared history unit size differs")
            }
            sharedRows = try QwenStagePrefixRestoreBuffer(bytes: frontier * rowBytes)
            sharedTokensBuffer = try QwenStagePrefixRestoreBuffer(bytes: (shared.prompt - 1) * tokens.size)
            sharedBlocks = (frontier + b - 1) / b
        } else {
            sharedRows = nil; sharedTokensBuffer = nil; sharedBlocks = 0
        }
        recurrentDone = Array(repeating: false, count: recurrentItems.count)
        historyDone = Array(repeating: false, count: historyItems.count)
    }

    func recurrentFilled(_ slot: Int) -> Bool { lock.withLock { recurrentDone[slot] } }
    func historyFilled(_ slot: Int) -> Bool { lock.withLock { historyDone[slot] } }

    func requireNoError() throws {
        if let error = lock.withLock({ firstError }) { throw error }
    }

    private func open(_ unit: QwenStagePrefixDiskHeader.Unit) throws -> Data {
        try QwenStagePrefixDiskIO.readUnit(fd, unit, dataStart: dataStart, fileSize: fileSize, key: key, readCall: readCall)
    }

    func run(_ index: Int) {
        do {
            let b = header.blockTokens
            if index < attentionWork.count {
                let (entry, block) = attentionWork[index]
                let item = header.attention[entry], unit = item.units[block], target = targets[entry]
                let rows = min(b, header.committedTokens - block * b)
                guard unit.length == target.heads * rows * target.rowBytes + QwenStagePrefixDiskFormat.tagBytes,
                      rows == min(b, frontier - block * b) else { throw ProbeError("Prefix record unit size differs") }
                let plain = try open(unit)
                let run = rows * target.rowBytes
                plain.withUnsafeBytes { source in
                    for head in 0..<target.heads {
                        target.buffer.pointer.advanced(by: (head * frontier + block * b) * target.rowBytes)
                            .copyMemory(from: source.baseAddress!.advanced(by: head * run), byteCount: run)
                    }
                }
            } else if index < attentionWork.count + recurrentItems.count {
                let slot = index - attentionWork.count
                let plain = try open(recurrentItems[slot].unit)
                let target = recurrentBuffers[slot]
                guard plain.count == target.bytes else { throw ProbeError("Prefix record recurrent unit size differs") }
                if target.bytes > 0 { plain.withUnsafeBytes { target.pointer.copyMemory(from: $0.baseAddress!, byteCount: target.bytes) } }
                lock.withLock { recurrentDone[slot] = true }
            } else if index >= attentionWork.count + recurrentItems.count + historyItems.count {
                // Version 2 history: block `k` of rows [0, frontier), then the tokens.
                guard let shared = header.sharedHistory, let rows = sharedRows, let tokens = sharedTokensBuffer else {
                    throw ProbeError("Prefix record shared history missing")
                }
                let k = index - attentionWork.count - recurrentItems.count - historyItems.count
                if k < sharedBlocks {
                    let plain = try open(shared.hiddenUnits[k])
                    let rowBytes = rows.bytes / frontier, first = k * b
                    let take = min(b, frontier - first) * rowBytes
                    guard plain.count == min(b, shared.prompt - first) * rowBytes, take <= plain.count else {
                        throw ProbeError("Prefix record shared history unit size differs")
                    }
                    plain.withUnsafeBytes { rows.pointer.advanced(by: first * rowBytes).copyMemory(from: $0.baseAddress!, byteCount: take) }
                } else {
                    let plain = try open(shared.tokens)
                    guard plain.count == tokens.bytes else { throw ProbeError("Prefix record shared history tokens differ") }
                    if tokens.bytes > 0 { plain.withUnsafeBytes { tokens.pointer.copyMemory(from: $0.baseAddress!, byteCount: tokens.bytes) } }
                }
                lock.withLock { sharedDone += 1 }
            } else {
                let slot = index - attentionWork.count - recurrentItems.count
                let plain = try open(historyItems[slot].unit)
                let target = historyBuffers[slot]
                guard plain.count == target.bytes else { throw ProbeError("Prefix record history unit size differs") }
                if target.bytes > 0 { plain.withUnsafeBytes { target.pointer.copyMemory(from: $0.baseAddress!, byteCount: target.bytes) } }
                lock.withLock { historyDone[slot] = true }
            }
        } catch {
            lock.withLock { if firstError == nil { firstError = error } }
        }
    }
}
