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
    static let version = 1
    let version: Int
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
    let createdUnixSeconds: Double

    var historyEntries: [Recurrent] { history ?? [] }

    /// Bytes of every sealed unit after the header.
    var dataBytes: Int {
        attention.reduce(0) { $0 + $1.units.reduce(0) { $0 + $1.length } } + recurrent.reduce(0) { $0 + $1.unit.length }
            + historyEntries.reduce(0) { $0 + $1.unit.length }
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

    init(header: QwenStagePrefixDiskHeader, fileName: String, attention: [Source], recurrent: [Source], history: [Source] = []) {
        self.header = header; self.fileName = fileName; self.attention = attention; self.recurrent = recurrent
        self.history = history
    }

    var hostBytes: Int {
        attention.reduce(0) { $0 + $1.data.count } + recurrent.reduce(0) { $0 + $1.data.count }
            + history.reduce(0) { $0 + $1.data.count }
    }

    /// Prepares a record of `states` (one prompt's captured frontiers, the
    /// deepest carrying the whole attention copy). Runs on the serving thread:
    /// it evaluates (normally a no-op) and borrows the arrays' bytes.
    static func prepare(scope: String, recordKey: String, fileName: String, deepest: QwenStagePrefixState,
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
        for (state, _) in frontiers.sorted(by: { $0.state.committedTokens < $1.state.committedTokens }) {
            guard let kept = state.speculativeHistory else { continue }
            guard kept.frontier == state.committedTokens, kept.hidden.ndim == 3, kept.tokens.ndim == 2, kept.last.ndim == 3,
                  kept.hidden.dim(1) == kept.frontier - 1, kept.tokens.dim(1) == kept.frontier - 1, kept.last.dim(1) == 1 else {
                throw ProbeError("Prefix record speculative history does not describe its frontier")
            }
            for (kind, array) in [("hidden", kept.hidden), ("tokens", kept.tokens), ("last", kept.last)] {
                guard let dtype = QwenStagePrefixDiskFormat.name(array.dtype) else {
                    throw ProbeError("Prefix record history dtype is not storable")
                }
                let data = array.asData(access: .noCopyIfContiguous)
                guard data.data.count == array.nbytes else { throw ProbeError("Prefix record history bytes differ") }
                history.append(.init(frontier: state.committedTokens, layer: 0, kind: kind, dtype: dtype,
                    shape: array.shape, unit: unit(array.nbytes)))
                historySources.append(.init(array: array, data: data.data))
            }
        }
        var header = QwenStagePrefixDiskHeader(version: QwenStagePrefixDiskHeader.version, scope: scope, recordKey: recordKey,
            committedTokens: committed, blockTokens: blockTokens,
            frontiers: frontiers.map { .init(tokens: $0.state.committedTokens, key: $0.key) }.sorted { $0.tokens < $1.tokens },
            attention: attention, recurrent: recurrent, createdUnixSeconds: Date().timeIntervalSince1970)
        if !history.isEmpty { header.history = history }
        return .init(header: header, fileName: fileName, attention: attentionSources, recurrent: recurrentSources,
            history: historySources)
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
        closed = true
        guard close(fd) == 0 else { throw ProbeError("Prefix record close failed (errno \(errno))") }
        return dataStart + job.header.dataBytes
    }

    static func open(url: URL, keys: QwenStagePrefixDiskKeys) throws -> Opened {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProbeError("Prefix record could not be opened (errno \(errno))") }
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
        guard header.version == QwenStagePrefixDiskHeader.version, header.committedTokens > 0, header.blockTokens > 0,
              dataStart + header.dataBytes == size else {
            throw ProbeError("Prefix record header does not describe its file")
        }
        return .init(header: header, dataStart: dataStart, key: dek, fileBytes: size)
    }

    /// The state at `frontier` (one of the record's frontiers): attention rows
    /// `[0, frontier)` from the units that hold them, and that frontier's
    /// recurrent state. Units are read and opened in parallel; arrays are
    /// created on the calling (serving) thread. `stallMilliseconds`
    /// (qualification only) stops halfway, still calling `check`.
    static func restore(url: URL, opened: Opened, frontier: Int, stallMilliseconds: Int? = nil,
                        check: () throws -> Void) throws -> QwenStagePrefixState {
        let header = opened.header, b = header.blockTokens
        guard frontier > 0, frontier <= header.committedTokens,
              frontier == header.committedTokens || frontier % b == 0,
              header.frontiers.contains(where: { $0.tokens == frontier }) else {
            throw ProbeError("Prefix record does not hold that frontier")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProbeError("Prefix record could not be opened (errno \(errno))") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let work = try QwenStagePrefixDiskRestoreWork(fd: fd, opened: opened, frontier: frontier)
        try check()
        // First half, an optional qualification stall (the rank is checked
        // while it waits, as a stalled disk would be), then the rest.
        let halfway = work.total / 2
        DispatchQueue.concurrentPerform(iterations: halfway) { work.run($0) }
        try work.requireNoError()
        if let stallMilliseconds {
            log("darkbloom-prefix-ssd-v1 event=qualification-stall ms=\(stallMilliseconds)")
            let end = DispatchTime.now().uptimeNanoseconds + UInt64(stallMilliseconds) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < end { try check(); usleep(20_000) }
        }
        try check()
        DispatchQueue.concurrentPerform(iterations: work.total - halfway) { work.run(halfway + $0) }
        try work.requireNoError()
        try check()
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var pending: [Int: MLXArray] = [:]
        for (entry, item) in header.attention.enumerated() {
            let target = work.targets[entry], dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype]!
            let array = MLXArray(Data(bytesNoCopy: target.pointer, count: target.bytes, deallocator: .none),
                [1, item.heads, frontier, item.headDim], dtype: dtype)
            if item.kind == "keys" { pending[item.layer] = array }
            else if item.kind == "values", let keys = pending.removeValue(forKey: item.layer) {
                attention[item.layer] = (keys: keys, values: array)
            } else { throw ProbeError("Prefix record attention entries are not paired") }
        }
        guard pending.isEmpty else { throw ProbeError("Prefix record attention entries are not paired") }
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        var convs: [Int: MLXArray] = [:]
        for (slot, item) in work.recurrentItems.enumerated() {
            guard let plain = work.recurrentPlain(slot), let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype] else {
                throw ProbeError("Prefix record recurrent unit missing")
            }
            let array = MLXArray(plain, item.shape, dtype: dtype)
            if item.kind == "conv" { convs[item.layer] = array }
            else if item.kind == "ssm", let conv = convs.removeValue(forKey: item.layer) {
                recurrent[item.layer] = (conv: conv, ssm: array)
            } else { throw ProbeError("Prefix record recurrent entries are not paired") }
        }
        guard convs.isEmpty else { throw ProbeError("Prefix record recurrent entries are not paired") }
        var historyArrays: [String: MLXArray] = [:]
        for (slot, item) in work.historyItems.enumerated() {
            guard let plain = work.historyPlain(slot), let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype] else {
                throw ProbeError("Prefix record history unit missing")
            }
            historyArrays[item.kind] = MLXArray(plain, item.shape, dtype: dtype)
        }
        var history: QwenMTPPrefixHistory?
        if !historyArrays.isEmpty {
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

    static func openUnit(_ fd: Int32, _ unit: QwenStagePrefixDiskHeader.Unit, dataStart: Int,
                                 key: SymmetricKey) throws -> Data {
        let sealed = try readAll(fd, count: unit.length, at: dataStart + unit.offset)
        let box = try AES.GCM.SealedBox(nonce: QwenStagePrefixDiskFormat.unitNonce(unit.index),
            ciphertext: sealed.prefix(unit.length - QwenStagePrefixDiskFormat.tagBytes),
            tag: sealed.suffix(QwenStagePrefixDiskFormat.tagBytes))
        return try AES.GCM.open(box, using: key)
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
                if n < 0 { if errno == EINTR { continue }; throw ProbeError("Prefix record read failed (errno \(errno))") }
                if n == 0 { throw ProbeError("Prefix record is shorter than its header says") }
                done += n
            }
        }
        return data
    }
}

/// The parallel part of one restore: every unit is read, authenticated and
/// copied into its place by whichever thread takes it. Output buffers are
/// disjoint per unit; the recurrent plaintexts and the first error are kept
/// under a lock. Nothing here calls MLX.
final class QwenStagePrefixDiskRestoreWork: @unchecked Sendable {
    struct Target { let pointer: UnsafeMutableRawPointer; let bytes: Int; let rowBytes: Int; let heads: Int }
    let fd: Int32
    let header: QwenStagePrefixDiskHeader
    let frontier: Int
    let dataStart: Int
    let key: SymmetricKey
    let targets: [Target]
    let attentionWork: [(entry: Int, block: Int)]
    let recurrentItems: [QwenStagePrefixDiskHeader.Recurrent]
    let historyItems: [QwenStagePrefixDiskHeader.Recurrent]
    private let lock = NSLock()
    private var plains: [Data?]
    private var historyPlains: [Data?]
    private var firstError: Error?

    var total: Int { attentionWork.count + recurrentItems.count + historyItems.count }

    init(fd: Int32, opened: QwenStagePrefixDiskIO.Opened, frontier: Int) throws {
        let header = opened.header, b = header.blockTokens
        self.fd = fd; self.header = header; self.frontier = frontier
        dataStart = opened.dataStart; key = opened.key
        var targets: [Target] = []
        for item in header.attention {
            guard let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype], item.units.count == (header.committedTokens + b - 1) / b,
                  item.heads > 0, item.headDim > 0 else {
                for target in targets { target.pointer.deallocate() }
                throw ProbeError("Prefix record attention entry is malformed")
            }
            let rowBytes = item.headDim * dtype.size, bytes = item.heads * frontier * rowBytes
            targets.append(.init(pointer: UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes), alignment: 64),
                bytes: bytes, rowBytes: rowBytes, heads: item.heads))
        }
        self.targets = targets
        let blocks = (frontier + b - 1) / b
        attentionWork = header.attention.indices.flatMap { entry in (0..<blocks).map { (entry: entry, block: $0) } }
        recurrentItems = header.recurrent.filter { $0.frontier == frontier }
        plains = Array(repeating: nil, count: recurrentItems.count)
        historyItems = header.historyEntries.filter { $0.frontier == frontier }
        historyPlains = Array(repeating: nil, count: historyItems.count)
        guard !recurrentItems.isEmpty || header.recurrent.isEmpty else {
            throw ProbeError("Prefix record lacks the frontier's recurrent state")
        }
    }

    deinit { for target in targets { target.pointer.deallocate() } }

    func recurrentPlain(_ slot: Int) -> Data? { lock.withLock { plains[slot] } }
    func historyPlain(_ slot: Int) -> Data? { lock.withLock { historyPlains[slot] } }

    func requireNoError() throws {
        if let error = lock.withLock({ firstError }) { throw error }
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
                let plain = try QwenStagePrefixDiskIO.openUnit(fd, unit, dataStart: dataStart, key: key)
                let run = rows * target.rowBytes
                plain.withUnsafeBytes { source in
                    for head in 0..<target.heads {
                        target.pointer.advanced(by: (head * frontier + block * b) * target.rowBytes)
                            .copyMemory(from: source.baseAddress!.advanced(by: head * run), byteCount: run)
                    }
                }
            } else if index < attentionWork.count + recurrentItems.count {
                let slot = index - attentionWork.count
                let item = recurrentItems[slot]
                guard let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype],
                      item.unit.length == item.shape.reduce(1, *) * dtype.size + QwenStagePrefixDiskFormat.tagBytes else {
                    throw ProbeError("Prefix record recurrent unit size differs")
                }
                let plain = try QwenStagePrefixDiskIO.openUnit(fd, item.unit, dataStart: dataStart, key: key)
                lock.withLock { plains[slot] = plain }
            } else {
                let slot = index - attentionWork.count - recurrentItems.count
                let item = historyItems[slot]
                guard let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype],
                      item.unit.length == item.shape.reduce(1, *) * dtype.size + QwenStagePrefixDiskFormat.tagBytes else {
                    throw ProbeError("Prefix record history unit size differs")
                }
                let plain = try QwenStagePrefixDiskIO.openUnit(fd, item.unit, dataStart: dataStart, key: key)
                lock.withLock { historyPlains[slot] = plain }
            }
        } catch {
            lock.withLock { if firstError == nil { firstError = error } }
        }
    }
}
