import CryptoKit
import Foundation

/// The encoded rows of an earlier record on this rank that holds a prefix of
/// the prompt being written: the record with the deepest kept frontier of
/// that prompt, `frontier`, pinned by the tier until the new record is
/// written (`QwenStagePrefixDiskTier.persist`).
///
/// The row codec is not idempotent on its own output: a key row is rotated
/// before it is quantized and rounded to its dtype after it is decoded, so
/// encoding a decoded row again gives other scales and offsets, and its decode
/// moves (FP32 value rows too). A request restored from an encoded record
/// holds such decoded rows, and a record written from it would drift a little
/// further each time. So the writer stores a row as the earlier record's
/// bytes for it whenever those decode to the row bit for bit
/// (`QwenStagePrefixDiskEncodedRows.encode(..., verbatim:)`): restored rows
/// keep their first encoding through every later record, and rows that did
/// not come from it (computed exactly, or from another state) are encoded as
/// usual. Only rows below both records' exact bands and below `frontier`
/// (rows of this prompt) are offered.
final class QwenStagePrefixDiskVerbatimSource: @unchecked Sendable {
    let frontier: Int
    private let opened: QwenStagePrefixDiskIO.Opened
    private let fd: Int32
    /// A source entry by layer and slot.
    private let entries: [String: QwenStagePrefixDiskHeader.Attention]

    /// Opens `url`, which must be a record of `scope` under `encoding` whose
    /// kept frontier `frontier` has `frontierKey` (a prefix of the new prompt).
    init(url: URL, keys: QwenStagePrefixDiskKeys, scope: String, encoding: QwenStagePrefixDiskEncoding, frontier: Int,
         frontierKey: String) throws {
        let opened = try QwenStagePrefixDiskIO.open(url: url, keys: keys)
        guard opened.header.scope == scope, opened.header.encoding == encoding.header,
              opened.header.frontiers.contains(where: { $0.tokens == frontier && $0.key == frontierKey }) else {
            throw ProbeError("Prefix record verbatim source does not hold this prompt")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw QwenStagePrefixDiskPolicy.IOFailure("open", code: errno) }
        _ = fcntl(fd, F_NOCACHE, 1)
        self.opened = opened; self.fd = fd; self.frontier = frontier
        entries = Dictionary(opened.header.attention.map { ("\($0.layer):\($0.kind)", $0) }, uniquingKeysWith: { first, _ in first })
    }

    deinit { close(fd) }

    /// The source's bytes for rows of `item` (the new record's entry, stored
    /// as `rows` says) in `[first, first + count)`, read and authenticated
    /// unit by unit; nil when the source holds none of them encoded. Throws
    /// when a unit it needs cannot be read or authenticated.
    func rows(of item: QwenStagePrefixDiskHeader.Attention, encoded rows: QwenStagePrefixDiskEncodedRows, first: Int,
              count: Int) throws -> QwenStagePrefixDiskEncodedRows.Verbatim? {
        guard let source = entries["\(item.layer):\(item.kind)"], source.dtype == item.dtype, source.heads == item.heads,
              source.headDim == item.headDim, let sourceNativeFrom = source.nativeFrom else { return nil }
        let end = min(first + count, frontier, sourceNativeFrom, rows.nativeFrom)
        guard end > first else { return nil }
        let layout = try QwenStagePrefixDiskEncodedRows(configuration: rows.configuration, dtype: rows.dtype, width: rows.width,
            values: rows.values, nativeFrom: sourceNativeFrom)
        guard layout.encodedRowBytes == rows.encodedRowBytes else { return nil }
        let b = opened.header.blockTokens, committed = opened.header.committedTokens
        var units: [Int: (plain: Data, first: Int, run: Int)] = [:]
        for block in first / b ... (end - 1) / b {
            guard block < source.units.count else { return nil }
            let unitFirst = block * b, run = layout.headBytes(first: unitFirst, rows: min(b, committed - unitFirst))
            let plain = try QwenStagePrefixDiskIO.readUnit(fd, source.units[block], dataStart: opened.dataStart,
                fileSize: opened.fileBytes, key: opened.key, readCall: { Darwin.pread($0, $1, $2, $3) })
            guard plain.count == source.heads * run else { throw ProbeError("Prefix record verbatim unit size differs") }
            units[block] = (plain, unitFirst, run)
        }
        let rowBytes = layout.encodedRowBytes
        return { head, row in
            guard row >= first, row < end, head >= 0, head < source.heads, let unit = units[row / b] else { return nil }
            let offset = unit.plain.startIndex + head * unit.run + (row - unit.first) * rowBytes
            return unit.plain.subdata(in: offset ..< offset + rowBytes)
        }
    }
}
