import Foundation

extension FileHandle {
    /// `read(upToCount:)` in its own autorelease pool: the returned bytes live
    /// only as long as the caller holds them.
    ///
    /// On Darwin `read(upToCount:)` returns autoreleased storage. A Swift
    /// concurrency thread drains no pool between jobs, and a Dispatch block
    /// drains none before it returns, so a loop that reads a file or a pipe in
    /// chunks otherwise keeps every chunk resident until that thread drains:
    /// memory grows with the bytes read. Errors, end of file (`nil` or empty)
    /// and the bytes are those of `read(upToCount:)`.
    public func readDrained(upToCount count: Int) throws -> Data? {
        #if canImport(ObjectiveC)
        return try autoreleasepool { try read(upToCount: count) }
        #else
        return try read(upToCount: count)
        #endif
    }
}
