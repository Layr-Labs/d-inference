import Foundation
import Testing
@testable import ProviderCore

/// A Secure Boot reading says why it is unknown, the service reads again after a failed read (about a minute at most),
/// and the registration reports why it stayed unknown and after how many reads.
@Suite("Secure Boot reading: why it failed, and reading again")
struct SecureBootReadingTests {
    private static let command = ["/usr/sbin/system_profiler", "-json", "SPiBridgeDataType"]

    private static func report(_ json: String, status: Int32 = 0, stderr: String = "") -> SecurityCommandRunner {
        SecurityCommandRunner { path, arguments in
            #expect([path] + arguments == SecureBootReadingTests.command)
            return SecurityCommandResult(terminationStatus: status, stdout: json, stderr: stderr)
        }
    }

    private static func value(_ value: String) -> String {
        #"{"SPiBridgeDataType":[{"ibridge_sb_sip":"Enabled","ibridge_secure_boot":"\#(value)"}]}"#
    }

    @Test("each way the report can fail has its own reason")
    func classifiesEachFailure() {
        let cases: [(String, SecureBootReadFailure)] = [
            ("", .notJSON), ("not json", .notJSON), ("[]", .notJSON),
            ("{}", .noReport), (#"{"SPiBridgeDataType":[]}"#, .noReport), (#"{"SPiBridgeDataType":"none"}"#, .noReport),
            (#"{"SPiBridgeDataType":[{}]}"#, .noValue), (#"{"SPiBridgeDataType":[{"ibridge_secure_boot":1}]}"#, .noValue),
            (Self.value("Sécurité maximale"), .unrecognizedValue), (Self.value(""), .unrecognizedValue),
        ]
        for (json, failure) in cases {
            let reading = SecureBootPolicy.classify(systemProfilerJSON: Data(json.utf8))
            #expect(reading.failure == failure, "\(json.debugDescription)")
            #expect(reading.policy == .unknown, "\(json.debugDescription)")
            #expect(SecureBootPolicy.parse(systemProfilerJSON: Data(json.utf8)) == .unknown)
        }
        for (label, policy) in [("Full Security", SecureBootPolicy.full), ("Reduced Security", .reduced),
                                ("Medium Security", .reduced), ("Permissive Security", .permissive), ("No Security", .permissive)] {
            let reading = SecureBootPolicy.classify(systemProfilerJSON: Data(Self.value(label).utf8))
            #expect(reading == SecureBootReading(policy: policy), "\(label)")
        }
    }

    @Test("the log detail names what the report held, on one line")
    func failureDetail() {
        let noValue = SecureBootPolicy.classify(systemProfilerJSON: Data(
            #"{"SPiBridgeDataType":[{"ibridge_build":"x","ibridge_boot_uuid":"y"}]}"#.utf8))
        #expect(noValue.detail.contains("ibridge_boot_uuid, ibridge_build"))
        let unrecognized = SecureBootPolicy.classify(systemProfilerJSON: Data(Self.value("Sécurité maximale").utf8))
        #expect(unrecognized.detail.contains("Sécurité maximale"))
        let failed = SecureBootPolicy.read(runner: Self.report("", status: 1, stderr: "first\u{1B}[31m line\nsecond line\n"))
        #expect(failed.failure == .exitStatus)
        #expect(failed.detail.contains("exit status 1"))
        #expect(failed.detail.contains("first") && failed.detail.contains("line"))
        #expect(!failed.detail.contains("second"), "only stderr's first line")
        #expect(!failed.detail.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        let long = SecureBootPolicy.classify(systemProfilerJSON: Data(Self.value(String(repeating: "x", count: 500)).utf8))
        #expect(long.detail.count < 200)
    }

    @Test("one read: a timeout, a failed start, an exit status and a read policy")
    func singleRead() {
        let timedOut = SecureBootPolicy.read(runner: SecurityCommandRunner { _, _ in
            throw SecurityCommandRunner.CommandError.timedOut
        })
        #expect(timedOut.failure == .timedOut)
        #expect(timedOut.policy == .unknown)
        let notStarted = SecureBootPolicy.read(runner: SecurityCommandRunner { _, _ in
            throw CocoaError(.fileNoSuchFile)
        })
        #expect(notStarted.failure == .launchFailed)
        #expect(SecureBootPolicy.read(runner: Self.report(Self.value("Full Security"), status: 1)).failure == .exitStatus)
        let full = SecureBootPolicy.read(runner: Self.report(Self.value("Full Security")))
        #expect(full == SecureBootReading(policy: .full))
        #expect(full.attempts == 1)
        #expect(SecureBootPolicy.current(runner: Self.report(Self.value("Full Security"))) == .full)
        #expect(SecureBootPolicy.commandTimeout == 20)
    }

    /// A clock that only the reads and waits move.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        private var recorded: [TimeInterval] = []
        var now: TimeInterval { lock.withLock { time } }
        var waits: [TimeInterval] { lock.withLock { recorded } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
        func wait(_ seconds: TimeInterval) { lock.withLock { recorded.append(seconds); time += seconds } }
    }

    /// Reads `answers` in order (the last repeats), each taking `takes` seconds, or its whole bound when it times out.
    private static func retrying(_ answers: [SecureBootReading], takes: TimeInterval = 0.3,
                                 retry: SecureBootReadRetry = .service, clock: Clock = Clock(),
                                 cancelled: Bool = false)
        async -> (reading: SecureBootReading, timeouts: [TimeInterval], failures: [(Int, TimeInterval?)], clock: Clock) {
        var timeouts: [TimeInterval] = []
        var failures: [(Int, TimeInterval?)] = []
        let reading = await SecureBootPolicy.readRetrying(retry, now: { clock.now }, sleep: { seconds in
            if cancelled { throw CancellationError() }
            clock.wait(seconds)
        }, read: { timeout in
            timeouts.append(timeout)
            let answer = answers[min(timeouts.count, answers.count) - 1]
            clock.advance(answer.failure == .timedOut ? timeout : takes)
            return answer
        }, onFailure: { failed, next in
            failures.append((failed.attempts, next))
        })
        return (reading, timeouts, failures, clock)
    }

    @Test("a first read that works is the answer: one read, no wait")
    func firstReadWorks() async {
        let result = await Self.retrying([SecureBootReading(policy: .full)])
        #expect(result.reading == SecureBootReading(policy: .full))
        #expect(result.timeouts == [20])
        #expect(result.clock.waits.isEmpty)
    }

    @Test("a failed read is read again: two failures, then Full Security on the third read")
    func readsAgainAfterAFailure() async {
        let failed = SecureBootReading(failure: .exitStatus, detail: "exit status 1")
        let result = await Self.retrying([failed, failed, SecureBootReading(policy: .full)])
        #expect(result.reading == SecureBootReading(policy: .full, attempts: 3))
        #expect(result.clock.waits == [1, 2])
        #expect(result.failures.map { $0.0 } == [1, 2])
        #expect(result.failures.map { $0.1 } == [1, 2])
    }

    @Test("a read that keeps failing ends within the minute: seven reads, 1 to 16 s apart, the last failure reported")
    func persistentFailureEndsWithinBudget() async {
        let result = await Self.retrying([SecureBootReading(failure: .noValue, detail: "report keys: none")])
        #expect(result.reading.policy == .unknown)
        #expect(result.reading.failure == .noValue)
        #expect(result.reading.attempts == 7)
        #expect(result.clock.waits == [1, 2, 4, 8, 16, 16])
        #expect(result.failures.map { $0.0 } == Array(1...7))
        #expect(result.failures.last?.1 == nil, "the last failure says no read follows")
        #expect(result.clock.now < SecureBootReadRetry.service.budget)
    }

    @Test("reads that time out share the minute: three reads, the last one shortened")
    func timeoutsShareTheBudget() async {
        let result = await Self.retrying([SecureBootReading(failure: .timedOut)])
        #expect(result.reading.failure == .timedOut)
        #expect(result.reading.attempts == 3)
        #expect(result.timeouts == [20, 20, 17])
        #expect(result.clock.waits == [1, 2])
        #expect(result.clock.now <= SecureBootReadRetry.service.budget)
    }

    @Test("a downgrade found on a later read is the answer")
    func laterDowngrade() async {
        let result = await Self.retrying([SecureBootReading(failure: .timedOut), SecureBootReading(policy: .reduced)])
        #expect(result.reading == SecureBootReading(policy: .reduced, attempts: 2))
    }

    @Test("a cancelled wait ends the reading with the failure so far")
    func cancelledWait() async {
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)], cancelled: true)
        #expect(result.reading.failure == .exitStatus)
        #expect(result.reading.attempts == 1)
    }

    @Test("the service's schedule: about a minute, 1 s doubling to 16 s, 20 s per read")
    func serviceSchedule() {
        #expect(SecureBootReadRetry.service == SecureBootReadRetry(budget: 60, firstWait: 1, maxWait: 16, readTimeout: 20))
    }

    private func snapshot(_ reading: SecureBootReading) -> BootSecuritySnapshot {
        BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                             secureBoot: reading.policy, secureBootReadFailure: reading.failure,
                             secureBootReadAttempts: reading.attempts)
    }

    @Test("doctor and status say why Secure Boot could not be read, and after how many reads")
    func summaryNamesTheReason() {
        for failure in SecureBootReadFailure.allCases {
            let once = snapshot(SecureBootReading(failure: failure))
            #expect(once.secureBootSummary == "could not be read (`system_profiler SPiBridgeDataType`: \(failure.summary))")
            #expect(once.secureBootVerdict == .warn)
            #expect(once.servingRefusals.isEmpty, "unread only warns")
        }
        #expect(snapshot(SecureBootReading(failure: .timedOut, attempts: 3)).secureBootSummary
                == "could not be read (`system_profiler SPiBridgeDataType`: no answer in time, 3 tries)")
        #expect(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled).secureBootSummary
                == "could not be read (`system_profiler SPiBridgeDataType`)", "without a reading, no reason")
        #expect(Set(SecureBootReadFailure.allCases.map(\.rawValue)) == [
            "timed_out", "launch_failed", "exit_status", "not_json", "no_report", "no_value", "unrecognized_value",
        ])
    }

    @Test("live(runner:) carries the reason; a later reading replaces it and the reads add up")
    func snapshotCarriesTheReading() {
        let commands = SecurityCommandRunner { path, arguments in
            switch [path] + arguments {
            case ["/usr/bin/csrutil", "status"]:
                return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
            case ["/usr/bin/csrutil", "authenticated-root", "status"]:
                return SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: enabled\n")
            case SecureBootReadingTests.command:
                return SecurityCommandResult(terminationStatus: 0, stdout: #"{"SPiBridgeDataType":[{}]}"#)
            default:
                throw SecurityCommandRunner.CommandError.timedOut
            }
        }
        let unread = BootSecuritySnapshot.live(runner: commands, kernelSIP: { SIPConfiguration(rawValue: 0) })
        #expect(unread.secureBoot == .unknown)
        #expect(unread.secureBootReadFailure == .noValue)
        #expect(unread.secureBootReadAttempts == 1)

        let given = BootSecuritySnapshot.live(runner: commands, kernelSIP: { SIPConfiguration(rawValue: 0) },
                                              secureBoot: SecureBootReading(failure: .timedOut, attempts: 3))
        #expect(given.secureBootReadFailure == .timedOut)
        #expect(given.secureBootReadAttempts == 3)

        let stillUnread = given.rereadingSecureBoot(SecureBootReading(failure: .exitStatus))
        #expect(stillUnread.secureBoot == .unknown)
        #expect(stillUnread.secureBootReadFailure == .exitStatus)
        #expect(stillUnread.secureBootReadAttempts == 4)
        let read = stillUnread.rereadingSecureBoot(SecureBootReading(policy: .full))
        #expect(read.secureBoot == .full)
        #expect(read.secureBootReadFailure == nil)
        #expect(read.secureBootReadAttempts == 5)
        #expect(read.sipConfiguration == given.sipConfiguration && read.authenticatedRoot == given.authenticatedRoot)
        // A policy that was read keeps no reason.
        #expect(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, secureBoot: .full,
                                     secureBootReadFailure: .timedOut).secureBootReadFailure == nil)
    }

    @Test("the registration reports why Secure Boot is unknown and after how many reads, and nothing more otherwise")
    func registrationReportsTheReason() throws {
        let capabilities = PrivacyCapabilities(textBackendInprocess: true, textProxyDisabled: true, sipEnabled: true,
                                               antiDebugEnabled: true, coreDumpsDisabled: true, envScrubbed: true)
        func encoded(_ snapshot: BootSecuritySnapshot) throws -> [String: Any] {
            let reported = capabilities.reportingBootSecurity(snapshot)
            #expect(try JSONDecoder().decode(PrivacyCapabilities.self, from: JSONEncoder().encode(reported)) == reported)
            return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reported)) as? [String: Any])
        }
        let unread = try encoded(snapshot(SecureBootReading(failure: .timedOut, attempts: 3)))
        #expect(unread["secure_boot"] as? String == "unknown")
        #expect(unread["secure_boot_read_failure"] as? String == "timed_out")
        #expect(unread["secure_boot_read_attempts"] as? Int == 3)

        for reading in [SecureBootReading(policy: .full, attempts: 4), SecureBootReading(policy: .permissive)] {
            let read = try encoded(snapshot(reading))
            #expect(read.keys.contains("secure_boot_read_failure") == false)
            #expect(read.keys.contains("secure_boot_read_attempts") == false)
        }
        // A snapshot built without a reading has no reason to report.
        let noReading = try encoded(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled))
        #expect(noReading["secure_boot"] as? String == "unknown")
        #expect(noReading.keys.contains("secure_boot_read_failure") == false)
        #expect(noReading.keys.contains("secure_boot_read_attempts") == false)
    }
}
