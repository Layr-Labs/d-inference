import Foundation
import Testing
@testable import ProviderCore

struct AbsentProviderRecoveryAdapterTests {
    @Test func boundedProbeAdapterUsesOnlyExpectedCommand() throws {
        let runner = SecurityCommandRunner { executable, arguments in
            #expect(executable == "/bin/launchctl")
            #expect(arguments.count == 2)
            #expect(arguments.first == "print")
            return .init(terminationStatus: 0)
        }
        #expect(try AbsentProviderRecovery.jobIsLoaded(runner: runner))
    }

    @Test func probeDistinguishesConfirmedAbsenceFromUnknownErrors() throws {
        for status in [Int32(3), Int32(113)] {
            let runner = SecurityCommandRunner { _, _ in
                .init(terminationStatus: status, stderr: "Could not find service \"\(LaunchAgent.label)\" in domain for user gui")
            }
            #expect(try AbsentProviderRecovery.jobIsLoaded(runner: runner) == false)
        }
        let unknown = SecurityCommandRunner { _, _ in
            .init(terminationStatus: 1, stderr: "Operation not permitted")
        }
        #expect(throws: AbsentProviderRecovery.RecoveryError.self) {
            try AbsentProviderRecovery.jobIsLoaded(runner: unknown)
        }
    }

    @Test func boundedRunnerTimeoutIsNotInterpretedAsAbsence() {
        let timedOut = SecurityCommandRunner { _, _ in
            throw SecurityCommandRunner.CommandError.timedOut
        }
        #expect(throws: SecurityCommandRunner.CommandError.self) {
            try AbsentProviderRecovery.jobIsLoaded(runner: timedOut)
        }
    }
}
