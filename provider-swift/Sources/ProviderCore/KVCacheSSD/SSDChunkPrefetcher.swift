// Copyright © 2026 Eigen Labs.

import Foundation

/// Reads and authenticates one streamed file's remaining chunks ahead of its
/// consumer: a single reader task takes the chunks in file order (seeking past
/// the ones the plan skips) and hands each sealed chunk to a concurrent decrypt;
/// `next` returns the results strictly in file order. At most `depth` chunks
/// are read but not yet consumed. Every chunk is still authenticated before its
/// plaintext is returned, and an error surfaces at the chunk that caused it.
/// The consumer must call `finish` (normal end) or `cancel` (early exit) before
/// the cursor is used again; both wait until no work touches the file.
final class SSDChunkPrefetcher: @unchecked Sendable {
    /// One planned chunk: its index and whether the consumer skips it unread.
    struct Planned: Equatable { let index: Int, skip: Bool }

    private let cursor: SSDBlockChunkCursor
    private let plan: [Planned]
    private let lock = NSCondition()
    private var results: [Int: Result<Data, Error>] = [:]
    private var consumed = 0
    private var stopped = false
    private var readerDone = false
    private var inFlightDecrypts = 0
    private let window: DispatchSemaphore
    /// Process-wide cap on chunks being authenticated at once, across stages.
    static let maximumConcurrentOpens = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    private static let decryptQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "darkbloom.ssd.chunk-decrypt"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = maximumConcurrentOpens
        return queue
    }()

    init(cursor: SSDBlockChunkCursor, plan: [Planned], depth: Int) {
        precondition(depth >= 1)
        self.cursor = cursor
        self.plan = plan
        self.window = DispatchSemaphore(value: depth)
        let reader = Thread { [self] in read() }
        reader.qualityOfService = .userInitiated
        reader.start()
    }

    private func read() {
        for (slot, planned) in plan.enumerated() {
            window.wait()
            if lock.withLock({ stopped }) { break }
            let sealed: Result<SSDBlockChunkCursor.Sealed?, Error> = Result {
                guard cursor.nextIndex == planned.index else {
                    throw SSDBlockStoreError.malformedHeader("prefetch plan out of order")
                }
                return try cursor.readSealed(skip: planned.skip)
            }
            switch sealed {
            case .failure(let error):
                deliver(slot, .failure(error))
                lock.withLock { readerDone = true; lock.broadcast() }
                return
            case .success(nil):
                deliver(slot, .success(Data()))
            case .success(let box?):
                lock.withLock { inFlightDecrypts += 1 }
                Self.decryptQueue.addOperation { [self] in
                    // After a cancel nobody reads the result.
                    deliver(slot, lock.withLock { stopped } ? .failure(CancellationError()) : Result { try cursor.open(box) })
                    lock.withLock { inFlightDecrypts -= 1; lock.broadcast() }
                }
            }
        }
        lock.withLock { readerDone = true; lock.broadcast() }
    }

    private func deliver(_ slot: Int, _ result: Result<Data, Error>) {
        lock.withLock { results[slot] = result; lock.broadcast() }
    }

    /// The next planned chunk's plaintext (empty when skipped).
    func next(expectingIndex index: Int, skip: Bool) throws -> Data {
        let slot = lock.withLock { consumed }
        guard slot < plan.count, plan[slot] == Planned(index: index, skip: skip) else {
            throw SSDBlockStoreError.malformedHeader("prefetch plan mismatch")
        }
        let result: Result<Data, Error> = lock.withLock {
            while results[slot] == nil { lock.wait() }
            consumed += 1
            return results.removeValue(forKey: slot)!
        }
        window.signal()
        return try result.get()
    }

    /// Normal end (every planned chunk consumed) or early exit: stop reading and
    /// wait until no read or decrypt touches the file.
    func cancel() {
        lock.withLock { stopped = true; lock.broadcast() }
        for _ in 0..<plan.count { window.signal() }
        lock.withLock {
            while !readerDone || inFlightDecrypts > 0 { lock.wait() }
            results.removeAll()
        }
    }

    func finish() { cancel() }
}
