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
    private var order: [ObjectIdentifier: (ordinal: Int, reads: Int)] = [:]
    private var endedCount = 0

    init(ending: Set<Int>, atRead read: Int) {
        self.ending = ending
        self.read = read
    }

    var ended: Int { lock.withLock { endedCount } }

    var hook: @Sendable (AVAssetReader) -> Void {
        { [self] reader in
            let end = lock.withLock { () -> Bool in
                let id = ObjectIdentifier(reader)
                var entry = order[id] ?? (ordinal: order.count + 1, reads: 0)
                entry.reads += 1
                order[id] = entry
                guard entry.reads == read, ending.contains(entry.ordinal) else { return false }
                endedCount += 1
                return true
            }
            if end { reader.cancelReading() }
        }
    }
}
