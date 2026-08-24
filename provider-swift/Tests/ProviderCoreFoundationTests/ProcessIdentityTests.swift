import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Kernel process identity")
struct ProcessIdentityTests {
    @Test("the current PID round-trips through the kernel reader")
    func currentProcessRoundTrip() throws {
        let current = try #require(ProcessIdentity.current())
        let nowMicros = UInt64(
            Date().timeIntervalSince1970 * 1_000_000
        )
        #expect(current.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(current.startTimeMicros > 946_684_800_000_000)
        #expect(current.startTimeMicros <= nowMicros)
        #expect(ProcessIdentity.read(pid: current.pid) == current)
        #expect(current.isCurrent())
    }

    @Test("invalid and missing PIDs have no identity")
    func invalidPID() {
        #expect(ProcessIdentity.read(pid: 0) == nil)
        #expect(ProcessIdentity.read(pid: -1) == nil)
        #expect(ProcessIdentity.read(pid: 999_999_999) == nil)
    }
}
