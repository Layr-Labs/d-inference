// Copyright © 2026 Eigen Labs.

@preconcurrency import AVFoundation
import Foundation

/// Cancels the readers in `ending` (1 is the first reader the task opens)
/// before their read number `read`, through `VideoReaderRetry.beforeReadForTesting`
/// on the reading thread between two reads (the Super reader's queue, as its own
/// stop does). Each then ends `.cancelled` without having been stopped, as a
/// reader that fails partway ends `.failed`. The hook also runs before the read
/// that returns no sample, so read 2 comes on any track with one sample buffer.
final class ReaderEnder: @unchecked Sendable {
    private let lock = NSLock()
    private let ending: Set<Int>
    private let read: Int
    private var order = ReaderOrder()
    private var endedCount = 0

    init(ending: Set<Int>, atRead read: Int) {
        self.ending = ending
        self.read = read
    }

    var ended: Int { lock.withLock { endedCount } }

    var hook: @Sendable (AVAssetReader) -> Void {
        { [self] reader in
            let end = lock.withLock { () -> Bool in
                let (ordinal, reads) = order.count(readBy: reader)
                guard reads == read, ending.contains(ordinal) else { return false }
                endedCount += 1
                return true
            }
            if end { reader.cancelReading() }
        }
    }
}

/// The readers that have read, in the order of their first read. It keeps each
/// reader until it is released. A freed reader's address can go to the next
/// reader, so the `ObjectIdentifier` of a reader that is not kept can name a
/// later reader.
struct ReaderOrder {
    private var readers: [(reader: AVAssetReader, reads: Int)] = []

    var readerCount: Int { readers.count }

    /// Counts one read by `reader`. Returns the reader's ordinal (1 is the
    /// first reader) and its reads so far, this read included.
    @discardableResult
    mutating func count(readBy reader: AVAssetReader) -> (ordinal: Int, reads: Int) {
        let index: Int
        if let seen = readers.firstIndex(where: { $0.reader === reader }) {
            index = seen
        } else {
            readers.append((reader, 0))
            index = readers.count - 1
        }
        readers[index].reads += 1
        return (index + 1, readers[index].reads)
    }
}
