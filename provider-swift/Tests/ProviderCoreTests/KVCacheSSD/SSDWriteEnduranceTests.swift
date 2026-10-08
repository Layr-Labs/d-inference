import Foundation
import Testing
@testable import ProviderCore

@Suite("SSD write endurance across cache lifetimes")
struct SSDWriteEnduranceTests {
    private final class Clock: @unchecked Sendable {
        var seconds: Double = 0
    }

    @Test("a full day of writes stays capped even when the cache is rebuilt hourly", arguments: [false, true])
    func dailyCap(rebuildHourly: Bool) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ssd-endurance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let cap = 750_000_000_000
        func makeLimiter() throws -> SSDWriteRateLimiter {
            SSDWriteRateLimiter(capBytesPerDay: cap,
                writeBudget: try SSDWriteBudget(root: root), nowSeconds: { clock.seconds })
        }
        var limiter = try makeLimiter()
        var written = 0
        var refused = 0
        // The reported 88.51 MB/s offered load, advanced one minute at a time.
        let bytesPerMinute = 88_510_000 * 60
        for minute in 0..<1440 {
            clock.seconds = Double(minute * 60)
            if rebuildHourly && minute.isMultiple(of: 60) { limiter = try makeLimiter() }
            if limiter.tryConsume(bytes: bytesPerMinute) {
                written += bytesPerMinute
            } else {
                refused += 1
            }
        }
        #expect(written <= cap)
        #expect(written > cap - bytesPerMinute)
        #expect(refused > 0)
        #expect(!limiter.mightAccept(bytes: bytesPerMinute))
    }
}
