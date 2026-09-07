// Standalone optimized check compiled with the actual production helper:
// swiftc -O -swift-version 6 KVQualityDeadline.swift <this file> -o <temporary executable>
import Foundation

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@main
private struct ReleaseDeadlineCheck {
    static func main() async {
        let counter = Counter()
        let expired = KVQualityDeadline.start(startedAt: 0, maximumNanoseconds: 1) {
            counter.increment()
        }
        await expired.value
        precondition(counter.value == 1)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {
            var timers: [Task<Void, Never>] = []
            for _ in 0..<256 {
                timers.append(KVQualityDeadline.start(startedAt: DispatchTime.now().uptimeNanoseconds) {
                    counter.increment()
                })
            }
            timers.forEach { $0.cancel() }
            for timer in timers { await timer.value }
        }
        precondition(counter.value == 1, "cancelled timers invoked expiry")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        print("PASS: one expiry and 25,600 cancelled/awaited production timers under Swift -O in \(elapsed)s")
    }
}
