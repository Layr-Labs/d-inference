import Foundation

/// Accumulates up to `limit` bytes and records whether more arrived.
///
/// Reading must continue past the limit so a chatty command cannot deadlock on
/// a full pipe; this keeps the prefix and remembers that it discarded the rest.
struct BoundedSink {
    let limit: Int
    private(set) var bytes = Data()
    private(set) var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append<C: Collection>(_ incoming: C) where C.Element == UInt8 {
        let room = limit - bytes.count
        if room <= 0 {
            // Landing exactly on the limit is not truncation; only bytes that
            // had to be dropped are.
            if !incoming.isEmpty { truncated = true }
            return
        }
        if incoming.count <= room {
            bytes.append(contentsOf: incoming)
        } else {
            bytes.append(contentsOf: incoming.prefix(room))
            truncated = true
        }
    }
}
