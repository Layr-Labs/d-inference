import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Kernel process identity")
struct ProcessIdentityTests {
    @Test("the current PID round-trips through the kernel reader")
    func currentProcessRoundTrip() throws {
        let current = try #require(ProcessIdentity.current())
        #expect(current.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(current.startTimeMicros > 0)
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
