import Foundation
import Darwin

/// The checks run as named groups, each in a process of its own (`--group NAME`), as many at a time as the Mac has
/// cores. The flows mostly wait on scripted operations and on their terminals, so one process that ran every group in
/// turn kept a core busy for under a second of each second it ran (543 s of the Cluster Focused Checks' shard 2, run
/// 44654386274, 2026-11-20). Each group's state (its terminals, its temporary files, the checks' counts) stays in its
/// own process.
extension OnboardingChecks {
    /// One named group of checks.
    struct CheckGroup {
        let name: String
        let run: () -> Void
        init(_ name: String, _ run: @escaping () -> Void) { self.name = name; self.run = run }
    }

    /// The bound of one group, and of the whole run.
    static let runSeconds: Double = 600

    /// The line a group ends with: its counts.
    static let countsPrefix = "onboarding checks: "

    /// How many groups run at a time: `ONBOARDING_JOBS`, else one per core.
    static func groupJobs() -> Int {
        ProcessInfo.processInfo.environment["ONBOARDING_JOBS"].flatMap { Int($0) }.map { max(1, $0) }
            ?? ProcessInfo.processInfo.activeProcessorCount
    }

    /// Runs the group `name` in this process: its counts, then each failure; exit status 0 only when every check passed.
    static func runGroup(named name: String) -> Int32 {
        guard let group = groups.first(where: { $0.name == name }) else {
            print("onboarding checks: no group named \(name)")
            return 2
        }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(UInt32(runSeconds)); defer { alarm(0) }
        group.run()
        print(countsPrefix + "\(passed) passed, \(failures.count) failed")
        for failure in failures { print("FAIL " + failure) }
        return failures.isEmpty ? 0 : 1
    }

    /// A line on this process's output at once (a group's line shows as it ends, never at the end of the run).
    static func sayNow(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    /// The counts of a group's last line (`runGroup`), nil when it has none.
    static func counts(_ output: String) -> (passed: Int, failed: Int)? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(countsPrefix) }) else { return nil }
        let words = line.dropFirst(countsPrefix.count).split(separator: " ")
        guard words.count == 4, let passed = Int(words[0]), let failed = Int(words[2]) else { return nil }
        return (passed, failed)
    }

    /// Runs each group of `names` in its own process, `jobs` at a time, and says each group's seconds as it ends. A group
    /// that failed, ended without its counts or was ended by a signal passes nothing: its whole output follows its line,
    /// and its failures are said again at the end. Exit status 1 when any group did not pass, or when the whole run
    /// outlived `seconds` (the groups still running are stopped, and those not started are named).
    static func runGroups(_ names: [String], jobs: Int, seconds: Double) -> Int32 {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let ended = ClusterOnboardingMailbox<Int>()
        let wake = DispatchSemaphore(value: 0)
        let began = Date()
        var running = [Int: (process: Process, began: Date)]()
        var next = 0, passedChecks = 0, failedChecks = 0
        var times = [(name: String, seconds: Double)]()
        var notPassed = [String](), failureLines = [String]()

        func logFile(_ index: Int) -> URL { logs.appendingPathComponent("\(index).log") }
        func launch(_ index: Int) {
            FileManager.default.createFile(atPath: logFile(index).path, contents: nil)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--group", names[index]]
            let output = try? FileHandle(forWritingTo: logFile(index))
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { _ in ended.post(index); wake.signal() }
            do {
                try process.run()
                running[index] = (process, Date())
            } catch {
                notPassed.append(names[index])
                sayNow("FAIL [\(names[index])] could not start: \(error)")
            }
            try? output?.close()
        }
        func finish(_ index: Int) {
            guard let entry = running.removeValue(forKey: index) else { return }
            let name = names[index], took = Date().timeIntervalSince(entry.began)
            // Decoded leniently: a stray byte must not hide a group's counts and turn a pass into "no counts".
            let output = (try? Data(contentsOf: logFile(index))).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let counted = counts(output)
            let exited = entry.process.terminationReason == .exit, status = entry.process.terminationStatus
            passedChecks += counted?.passed ?? 0
            failedChecks += counted?.failed ?? 0
            times.append((name, took))
            let groupPassed = exited && status == 0 && counted?.failed == 0
            let end = exited ? (status == 124 ? "timed out after \(Int(runSeconds)) s" : "exit status \(status)") : "signal \(status)"
            var line = String(format: "%7.1f s  ", took) + name
            if let counted { line += ": \(counted.passed) passed, \(counted.failed) failed" } else { line += ": no counts" }
            if !groupPassed { line += " (\(end))" }
            sayNow(line)
            guard !groupPassed else { return }
            notPassed.append(name)
            for failure in output.split(separator: "\n") where failure.hasPrefix("FAIL ") {
                failureLines.append("FAIL [\(name)] " + String(failure.dropFirst(5)))
            }
            sayNow("---- output of \(name) ----")
            sayNow(output.hasSuffix("\n") ? String(output.dropLast()) : output)
            sayNow("---- end of \(name) ----")
        }

        while next < names.count || !running.isEmpty {
            // Checked before a launch: a group is never started only to be stopped at once as "still running".
            let left = seconds - Date().timeIntervalSince(began)
            guard left > 0 else { break }
            while running.count < jobs, next < names.count {
                launch(next)
                next += 1
            }
            _ = wake.wait(timeout: .now() + min(left, 5))
            for index in ended.take() { finish(index) }
        }
        // A group that ended since the last look is said as ended, not stopped.
        for index in ended.take() { finish(index) }
        for (index, entry) in running.sorted(by: { $0.key < $1.key }) {
            entry.process.terminate()
            notPassed.append(names[index])
            sayNow("FAIL [\(names[index])] still running when the whole run's \(Int(seconds)) s ran out; stopped")
        }
        for index in next..<names.count {
            notPassed.append(names[index])
            sayNow("FAIL [\(names[index])] not started: the whole run's \(Int(seconds)) s ran out")
        }

        let slowest = times.sorted { $0.seconds > $1.seconds }.prefix(10).map { $0.name + String(format: " %.1f s", $0.seconds) }
        sayNow("slowest groups: " + slowest.joined(separator: ", "))
        sayNow(countsPrefix + "\(passedChecks) passed, \(failedChecks) failed; \(names.count) groups, \(jobs) at a time, "
            + String(format: "%.1f s", Date().timeIntervalSince(began)))
        for line in failureLines { sayNow(line) }
        guard notPassed.isEmpty else {
            sayNow("groups that did not pass: " + notPassed.joined(separator: ", "))
            return 1
        }
        return 0
    }
}
