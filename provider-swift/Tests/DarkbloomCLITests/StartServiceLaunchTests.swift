import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// A release build serves the network only in a process Darkbloom's launchd
/// service started; any other start says so, asks launchd to start the
/// service, and exits (`Start.requireServiceLaunch`).
@Suite struct StartServiceLaunchTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    @Test func aRefusedStartAsksLaunchdForTheServiceAndExits() {
        for refusal in [ServiceLaunchCheck.Refusal.startedByAnotherProgram, .adopted, .notTheProviderJob, .unknown] {
            let started = Calls()
            #expect(throws: ExitCode.failure) {
                try Start.requireServiceLaunch(enforced: true, verdict: { .refuse(refusal) },
                                               startService: { started.record(); return true })
            }
            #expect(started.total == 1)
            let lines = Start.serviceLaunchRefusal(.refuse(refusal))
            #expect(lines?.first?.contains("does not serve the network") == true)
            #expect(lines?.last?.contains("start --local --here") == true)
        }
    }

    @Test func theServiceItselfStartsAsBefore() throws {
        let started = Calls()
        try Start.requireServiceLaunch(enforced: true, verdict: { .serve }, startService: { started.record(); return true })
        #expect(started.total == 0)
        #expect(Start.serviceLaunchRefusal(.serve) == nil)
    }

    @Test func aBuildThatDoesNotEnforceItNeverAsks() throws {
        let asked = Calls()
        try Start.requireServiceLaunch(enforced: false, verdict: { asked.record(); return .refuse(.unknown) },
                                       startService: { asked.record(); return true })
        #expect(asked.total == 0)
        // Tests and development run debug builds, which serve from a terminal; release builds enforce it.
        #if DEBUG
        #expect(!Start.enforcesServiceLaunch)
        #else
        #expect(Start.enforcesServiceLaunch)
        #endif
    }
}
