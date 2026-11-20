import Foundation
import Testing
@testable import ProviderCore

/// A Secure Boot reading says why it is unknown, the service reads again after a failed read (a minute at most),
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

    private static func entries(_ values: [String]) -> Data {
        let items = values.map { #"{"ibridge_secure_boot":"\#($0)"}"# }.joined(separator: ",")
        return Data(#"{"SPiBridgeDataType":[\#(items)]}"#.utf8)
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

    @Test("report entries that disagree: a downgrade decides, and an unrecognized value leaves it unknown")
    func mixedEntries() {
        #expect(SecureBootPolicy.classify(systemProfilerJSON: Self.entries(["Full Security", "Reduced Security"])).policy == .reduced)
        #expect(SecureBootPolicy.classify(systemProfilerJSON: Self.entries(["Full Security", "Permissive Security"])).policy == .permissive)
        #expect(SecureBootPolicy.classify(systemProfilerJSON: Self.entries(["Reduced Security", "Permissive Security"])).policy == .permissive)
        #expect(SecureBootPolicy.classify(systemProfilerJSON: Self.entries(["Sécurité", "Reduced Security"])).policy == .reduced)
        #expect(SecureBootPolicy.classify(systemProfilerJSON: Self.entries(["Full Security", "Sécurité"])).failure == .unrecognizedValue)
        #expect(SecureBootPolicy.classify(systemProfilerJSON: Self.entries(["Full Security", "Full Security"])).policy == .full)
        // An entry without a value, or one that isn't an object, never lets Full through, and never hides a downgrade.
        func report(_ items: String) -> SecureBootReading {
            SecureBootPolicy.classify(systemProfilerJSON: Data(#"{"SPiBridgeDataType":[\#(items)]}"#.utf8))
        }
        #expect(report(#"{"ibridge_secure_boot":"Full Security"},{}"#).failure == .noValue)
        #expect(report(#"{"ibridge_secure_boot":"Full Security"},"x""#).failure == .noValue)
        #expect(report(#"{"ibridge_secure_boot":"Full Security"},{"ibridge_secure_boot":2}"#).failure == .noValue)
        #expect(report(#"{},{"ibridge_secure_boot":"Reduced Security"}"#).policy == .reduced)
        #expect(report(#""x",{"ibridge_secure_boot":"Permissive Security"}"#).policy == .permissive)
    }

    @Test("text from the tool stays out of the public detail; the private detail is one capped line")
    func failureDetail() {
        let stderr = "first\u{1B}[31m line\nsecond line\n"
        let failed = SecureBootPolicy.read(runner: Self.report("", status: 1, stderr: stderr))
        #expect(failed.failure == .exitStatus)
        #expect(failed.detail.contains("exit status 1"))
        #expect(failed.detail.contains("0 bytes on stdout, \(stderr.utf8.count) on stderr"))
        #expect(!failed.detail.contains("first"), "no tool text in the public detail")
        #expect(failed.privateDetail.contains("first") && failed.privateDetail.contains("line"))
        #expect(!failed.privateDetail.contains("second"), "only stderr's first line")

        let noValue = SecureBootPolicy.classify(systemProfilerJSON: Data(
            #"{"SPiBridgeDataType":[{"ibridge_build":"x","ibridge_boot_uuid":"y"}]}"#.utf8))
        #expect(noValue.detail == "1 of 1 report entries without one")
        #expect(noValue.privateDetail == "report keys: ibridge_boot_uuid, ibridge_build")
        let unrecognized = SecureBootPolicy.classify(systemProfilerJSON: Data(Self.value("Sécurité maximale").utf8))
        #expect(!unrecognized.detail.contains("Sécurité"))
        #expect(unrecognized.privateDetail == "value: Sécurité maximale")

        // Control, format and line separator characters become spaces; the line is cut by bytes.
        let line = SecureBootPolicy.logText("a\u{1B}b\u{2028}c\u{2029}d\u{202E}e\u{200B}f\tg\rh\ni")
        #expect(line == "a b c d e f g h i")
        let long = SecureBootPolicy.logText(String(repeating: "é", count: 500))
        #expect(long.utf8.count <= 200)
        #expect(long.hasSuffix("…"))
        #expect(SecureBootReading(failure: .noValue, privateDetail: String(repeating: "x", count: 1_000)).privateDetail.utf8.count <= 200)
    }

    @Test("one read: a timeout, a failed start, an exit status, output too large and a read policy")
    func singleRead() {
        let timedOut = SecureBootPolicy.read(runner: SecurityCommandRunner { _, _ in
            throw SecurityCommandRunner.CommandError.timedOut
        })
        #expect(timedOut.failure == .timedOut)
        #expect(timedOut.policy == .unknown)
        let tooLarge = SecureBootPolicy.read(runner: SecurityCommandRunner { _, _ in
            throw SecurityCommandRunner.CommandError.outputTooLarge
        })
        #expect(tooLarge.failure == .outputTooLarge)
        let unreadable = SecureBootPolicy.read(runner: SecurityCommandRunner { _, _ in
            throw SecurityCommandRunner.CommandError.outputUnreadable
        })
        #expect(unreadable.failure == .outputUnreadable)
        let unobserved = SecureBootPolicy.read(runner: SecurityCommandRunner { _, _ in
            throw SecurityCommandRunner.CommandError.exitUnobserved
        })
        #expect(unobserved.failure == .exitUnobserved)
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
        #expect(SecureBootPolicy.outputLimit == 65_536)
    }

    @Test("the live runner caps each stream, and returns at its deadline even when a pipe stays open")
    func boundedOutput() throws {
        let runner = SecurityCommandRunner.bounded(timeout: 10, outputLimit: 65_536)
        for (stream, script) in [("stdout", "head -c 200000 /dev/zero"), ("stderr", "head -c 200000 /dev/zero >&2")] {
            let started = ContinuousClock.now
            #expect(throws: SecurityCommandRunner.CommandError.outputTooLarge, "\(stream)") {
                _ = try runner.run("/bin/sh", ["-c", script])
            }
            #expect(ContinuousClock.now - started < .seconds(5), "\(stream): stopped at the limit, not the deadline")
        }
        let answered = try runner.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"])
        #expect(answered.terminationStatus == 3)
        #expect(answered.stdout == "out" && answered.stderr == "err" && answered.wroteToStderr)
        #expect(try runner.run("/bin/sh", ["-c", "true"]).wroteToStderr == false)

        // A background process keeps stdout open after the command exits: the call still returns at its deadline.
        let short = SecurityCommandRunner.bounded(timeout: 1, outputLimit: 65_536)
        var started = ContinuousClock.now
        #expect(throws: SecurityCommandRunner.CommandError.timedOut) {
            _ = try short.run("/bin/sh", ["-c", "sleep 3 & echo started"])
        }
        #expect(ContinuousClock.now - started < .milliseconds(2_500))

        // Output that keeps arriving doesn't carry the call past its deadline.
        started = ContinuousClock.now
        #expect(throws: SecurityCommandRunner.CommandError.timedOut) {
            _ = try SecurityCommandRunner.bounded(timeout: 1, outputLimit: 1 << 20)
                .run("/bin/sh", ["-c", "while :; do echo x; sleep 0.005; done"])
        }
        #expect(ContinuousClock.now - started < .milliseconds(2_500))

        // A command that can't start says so, and isn't a timeout.
        #expect(throws: POSIXError.self) {
            _ = try runner.run("/nonexistent/system_profiler", [])
        }
    }

    @Test("the runner leaves no descriptor open, whether the command can't start or runs")
    func noDescriptorLeft() async throws {
        // Each call opens four descriptors, so ones left open would add hundreds (`OpenDescriptors`).
        let before = try OpenDescriptors.count()
        for _ in 0..<200 {
            _ = try? SecurityCommandRunner.bounded(timeout: 5, outputLimit: 1_024).run("/nonexistent/system_profiler", [])
        }
        var growth = try await OpenDescriptors.settledGrowth(since: before)
        #expect(growth < 100, "a failed start closes both pipes: \(growth) more open")
        for _ in 0..<100 {
            _ = try SecurityCommandRunner.bounded(timeout: 5, outputLimit: 1_024).run("/usr/bin/true", [])
        }
        growth = try await OpenDescriptors.settledGrowth(since: before)
        #expect(growth < 100, "a finished command's read ends close: \(growth) more open")
    }

    @Test("a check that comes after the deadline times out, even when the command finished first")
    func lateWakeTimesOut() throws {
        let paused = Flag()
        #expect(throws: SecurityCommandRunner.CommandError.timedOut) {
            _ = try BoundedCommand.run("/usr/bin/true", [], timeout: 0.3, outputLimit: 1_024, pauseBeforeCheck: {
                if !paused.isSet {
                    paused.set()
                    Thread.sleep(forTimeInterval: 0.6)
                }
            })
        }
        #expect(paused.isSet)
        #expect(try BoundedCommand.run("/usr/bin/true", [], timeout: 5, outputLimit: 1_024).terminationStatus == 0)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test("a command stopped at its deadline is killed and reaped")
    func stoppedCommandIsReaped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid").path
        #expect(throws: SecurityCommandRunner.CommandError.timedOut) {
            _ = try SecurityCommandRunner.bounded(timeout: 1, outputLimit: 65_536)
                .run("/bin/sh", ["-c", "echo $$ > '\(pidFile)'; exec sleep 30"])
        }
        let pid = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "killed and reaped: no process, not even a zombie")
    }

    /// A clock that only the reads and waits move.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        var now: TimeInterval { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private struct Retried {
        let reading: SecureBootReading
        let readStarts: [TimeInterval]
        let timeouts: [TimeInterval]
        let failures: [(Int, TimeInterval?)]
        let steps: Int
        let clock: Clock
    }

    /// Reads `answers` in order (the last repeats), each taking 0.25 s, or its whole bound when it times out. Each
    /// wait step moves the clock by its length, and step `oversleep.step` by `oversleep.by` more; the first failure
    /// callback moves it by `failureCallbackTakes`.
    private static func retrying(_ answers: [SecureBootReading], retry: SecureBootReadRetry = .service,
                                 oversleep: (step: Int, by: TimeInterval)? = nil, cancelled: Bool = false,
                                 stopAt: TimeInterval? = nil, failureCallbackTakes: TimeInterval = 0,
                                 cancelInStopCheckAt: TimeInterval? = nil) async -> Retried {
        let clock = Clock()
        var readStarts: [TimeInterval] = []
        var timeouts: [TimeInterval] = []
        var failures: [(Int, TimeInterval?)] = []
        var steps = 0
        let reading = await SecureBootPolicy.readRetrying(retry, now: { clock.now }, sleep: { seconds in
            if cancelled { throw CancellationError() }
            steps += 1
            clock.advance(seconds + (steps == oversleep?.step ? oversleep?.by ?? 0 : 0))
        }, shouldStop: {
            // The task is cancelled while the stop check runs, and the check still says go on.
            if let cancelAt = cancelInStopCheckAt, clock.now >= cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
            return stopAt.map { clock.now >= $0 } ?? false
        }, read: { timeout in
            readStarts.append(clock.now)
            timeouts.append(timeout)
            let answer = answers[min(timeouts.count, answers.count) - 1]
            clock.advance(answer.failure == .timedOut ? timeout : 0.25)
            return answer
        }, onFailure: { failed, next in
            failures.append((failed.attempts, next))
            if failures.count == 1 { clock.advance(failureCallbackTakes) }
        })
        return Retried(reading: reading, readStarts: readStarts, timeouts: timeouts, failures: failures, steps: steps,
                       clock: clock)
    }

    @Test("a first read that works is the answer: one read, no wait")
    func firstReadWorks() async {
        let result = await Self.retrying([SecureBootReading(policy: .full)])
        #expect(result.reading == SecureBootReading(policy: .full))
        #expect(result.timeouts == [20])
        #expect(result.clock.now == 0.25)
    }

    @Test("a failed read is read again: two failures, then Full Security on the third read")
    func readsAgainAfterAFailure() async {
        let failed = SecureBootReading(failure: .exitStatus, detail: "exit status 1")
        let result = await Self.retrying([failed, failed, SecureBootReading(policy: .full)])
        #expect(result.reading == SecureBootReading(policy: .full, attempts: 3))
        #expect(result.readStarts == [0, 1.25, 3.5], "1 s, then 2 s after each failed read")
        #expect(result.failures.map { $0.0 } == [1, 2])
        #expect(result.failures.map { $0.1 } == [1, 2])
    }

    @Test("a read that keeps failing ends within the minute: seven reads, 1 to 16 s apart, the last failure reported")
    func persistentFailureEndsWithinBudget() async {
        let result = await Self.retrying([SecureBootReading(failure: .noValue, detail: "1 report entries")])
        #expect(result.reading.policy == .unknown)
        #expect(result.reading.failure == .noValue)
        #expect(result.reading.attempts == 7)
        #expect(result.readStarts == [0, 1.25, 3.5, 7.75, 16, 32.25, 48.5])
        #expect(result.failures.map { $0.0 } == Array(1...7))
        #expect(result.failures.map { $0.1 } == [1, 2, 4, 8, 16, 16, nil], "the last failure says no read follows")
        #expect(result.clock.now < SecureBootReadRetry.service.budget)
    }

    @Test("reads that time out share the minute: three reads, the last one cut to what is left")
    func timeoutsShareTheBudget() async {
        let result = await Self.retrying([SecureBootReading(failure: .timedOut)])
        #expect(result.reading.failure == .timedOut)
        #expect(result.reading.attempts == 3)
        #expect(result.timeouts == [20, 20, 17])
        #expect(result.readStarts == [0, 21, 43])
        #expect(result.clock.now == SecureBootReadRetry.service.budget)
    }

    @Test("a wait that oversleeps the budget starts no read")
    func oversleptWait() async {
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)], oversleep: (step: 1, by: 100))
        #expect(result.reading.failure == .exitStatus)
        #expect(result.reading.attempts == 1)
        #expect(result.readStarts == [0])
    }

    @Test("a step that oversleeps in the middle of a long wait ends that wait at once")
    func oversleptStepInALongWait() async {
        // Steps 1 to 15 are the 1, 2, 4 and 8 s waits; step 17 is the second of the 16 s wait.
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)], oversleep: (step: 17, by: 100))
        #expect(result.steps == 17, "no step after the overslept one")
        #expect(result.reading.attempts == 5)
        #expect(result.readStarts == [0, 1.25, 3.5, 7.75, 16])
    }

    @Test("a stop during a wait ends the reading within a second")
    func stopDuringAWait() async {
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)], stopAt: 20)
        #expect(result.reading.failure == .exitStatus)
        #expect(result.reading.attempts == 5, "the fifth read ended at 16.25 s; its wait was stopped")
        #expect(result.clock.now == 20.25, "heard on the first one-second step past 20 s")
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

    @Test("a failure callback that takes the rest of the budget starts no wait and no read")
    func slowFailureCallback() async {
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)], failureCallbackTakes: 100)
        #expect(result.failures.map { $0.1 } == [1], "the wait was decided before the callback")
        #expect(result.steps == 0)
        #expect(result.reading.attempts == 1)
        #expect(result.readStarts == [0])
    }

    @Test("a stop asked for while the failure callback ran is heard before the next read")
    func stopDuringTheFailureCallback() async {
        // The callback takes past the 1 s wake but not the budget; a stop came meanwhile.
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)], stopAt: 2, failureCallbackTakes: 2)
        #expect(result.steps == 0)
        #expect(result.reading.attempts == 1, "no read after the stop")
    }

    @Test("a cancellation during the stop check starts no read, even when the check says go on")
    func cancelledDuringTheStopCheck() async {
        // The failure callback takes the whole wait, so only the check before the next read runs.
        let result = await Task {
            await Self.retrying([SecureBootReading(failure: .exitStatus)], failureCallbackTakes: 2,
                                cancelInStopCheckAt: 2)
        }.value
        #expect(result.steps == 0)
        #expect(result.reading.attempts == 1, "no read after the cancellation")
    }

    @Test("a first read always runs, with at least a second, whatever the budget")
    func firstReadUnderASmallBudget() async {
        let result = await Self.retrying([SecureBootReading(failure: .exitStatus)],
                                         retry: SecureBootReadRetry(budget: 0.2, firstWait: 1, maxWait: 1, readTimeout: 20))
        #expect(result.timeouts == [1])
        #expect(result.reading.attempts == 1)
        #expect(result.steps == 0)
    }

    #if DEBUG
    /// Records the commands a collection ran.
    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        func note(_ command: [String]) { lock.withLock { commands.append(command) } }
        var all: [[String]] { lock.withLock { commands } }
    }

    @Test("a stop before or during the Secure Boot reads ends the collection: no later probe runs")
    func stopEndsTheCollection() async {
        func collect(stopAfterReads: Int) async -> (SecurityPosture?, [[String]]) {
            let ran = Ran()
            let commands = SecurityCommandRunner { path, arguments in
                ran.note([path] + arguments)
                if path == "/usr/sbin/system_profiler" { return SecurityCommandResult(terminationStatus: 1) }
                return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
            }
            let posture = await collectSecurityPostureWithoutHardening(
                bootSettingsCommands: commands, kernelSIP: { SIPConfiguration(rawValue: 0) },
                secureBootRetry: SecureBootReadRetry(budget: 3, firstWait: 0.05, maxWait: 0.05, readTimeout: 1),
                secureBootStop: { ran.all.count >= stopAfterReads })
            return (posture, ran.all)
        }
        let atEntry = await collect(stopAfterReads: 0)
        #expect(atEntry.0 == nil)
        #expect(atEntry.1.isEmpty, "nothing ran")
        let afterARead = await collect(stopAfterReads: 1)
        #expect(afterARead.0 == nil)
        #expect(afterARead.1 == [SecureBootReadingTests.command], "only the Secure Boot read ran")
    }
    #endif

    @Test("the service's schedule: a minute, 1 s doubling to 16 s, 20 s per read")
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
            "timed_out", "launch_failed", "exit_status", "exit_unobserved", "output_too_large", "output_unreadable",
            "not_json", "no_report", "no_value", "unrecognized_value",
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
        let unread = try encoded(snapshot(SecureBootReading(failure: .timedOut, privateDetail: "stderr: x", attempts: 3)))
        #expect(unread["secure_boot"] as? String == "unknown")
        #expect(unread["secure_boot_read_failure"] as? String == "timed_out")
        #expect(unread["secure_boot_read_attempts"] as? Int == 3)
        #expect(Set(unread.keys).isSubset(of: [
            "text_backend_inprocess", "text_proxy_disabled", "sip_enabled", "anti_debug_enabled", "core_dumps_disabled",
            "env_scrubbed", "sip_configuration", "secure_boot", "secure_boot_read_failure", "secure_boot_read_attempts",
            "authenticated_root",
        ]), "no detail reaches the report")

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
