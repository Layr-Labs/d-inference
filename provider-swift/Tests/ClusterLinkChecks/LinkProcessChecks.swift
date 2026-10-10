import Foundation
import Darwin

extension ClusterLinkCheck {
    /// The descriptors this process holds open; a check this small stays far below 1024.
    private static func openDescriptors() -> [Int32] {
        (Int32(0)..<1024).filter { fcntl($0, F_GETFD) != -1 }
    }

    private static func run(_ executable: String, _ arguments: [String] = [], seconds: Double = 5,
                            maximumOutputBytes: Int = 4096) -> (outcome: ClusterLinkToolOutcome, elapsed: Double) {
        let began = DispatchTime.now().uptimeNanoseconds
        let outcome = ClusterLinkToolProcess.run(executable: executable, arguments: arguments,
            deadline: began + UInt64(seconds * 1_000_000_000), maximumOutputBytes: maximumOutputBytes)
        return (outcome, Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000)
    }

    /// The real runner against harmless system binaries: no RDMA or network
    /// tool is started here.
    static func boundedChildProcess() {
        expectEqual(run("/bin/echo", ["rdma", "text"]).outcome, .output("rdma text\n"), "captured standard output")
        // Taken after one run, so anything Foundation opens once is already open.
        let descriptorsBefore = openDescriptors()
        expectEqual(run("/usr/bin/false").outcome, .unavailable, "non-zero exit")
        expectEqual(run("/nonexistent/darkbloom-link-tool").outcome, .unavailable, "missing tool")
        expectEqual(run("/bin/sh", ["-c", "kill -TERM $$"]).outcome, .unavailable, "signalled child")
        expectEqual(run("/bin/sh", ["-c", "echo diagnostic >&2"]).outcome, .output(""), "standard error is not captured")

        // Standard input is the null device, so a reader sees end-of-file at once.
        let reader = run("/bin/cat")
        expectEqual(reader.outcome, .output(""), "no inherited standard input")
        expect(reader.elapsed < 2, "reading standard input returned promptly")

        let environment = run("/usr/bin/env")
        expectEqual(environment.outcome.sortedLines, .output("LANG=C\nLC_ALL=C\nPATH=/usr/bin:/bin:/usr/sbin:/sbin"),
            "fixed minimal environment")

        let slow = run("/bin/sleep", ["30"], seconds: 0.3)
        expectEqual(slow.outcome, .timedOut, "hard timeout")
        expect(slow.elapsed < 3, "timed-out child was killed, not awaited (\(slow.elapsed) s)")

        // A child that closes its output but keeps running is still bounded.
        let lingering = run("/bin/sh", ["-c", "exec sleep 30 >&-"], seconds: 0.3)
        expectEqual(lingering.outcome, .timedOut, "hard timeout after output closed")
        expect(lingering.elapsed < 3, "lingering child was killed (\(lingering.elapsed) s)")

        let flood = run("/usr/bin/yes", maximumOutputBytes: 64 * 1024)
        expectEqual(flood.outcome, .outputTooLarge, "bounded output capture")
        expect(flood.elapsed < 3, "flooding child was stopped at the bound (\(flood.elapsed) s)")

        let exact = run("/bin/sh", ["-c", "printf 12345678"], maximumOutputBytes: 8)
        expectEqual(exact.outcome, .output("12345678"), "output exactly at the bound")
        expectEqual(run("/bin/sh", ["-c", "printf 123456789"], maximumOutputBytes: 8).outcome, .outputTooLarge, "one byte past the bound")

        expectEqual(run("/bin/sleep", ["30"], seconds: 0).outcome, .timedOut, "an expired deadline starts nothing")

        // The approval step needs the exit status and what the tool said about a failure.
        func execute(_ script: String, merging: Bool = true) -> ClusterLinkToolProcess.Execution {
            ClusterLinkToolProcess.execute(executable: "/bin/sh", arguments: ["-c", script],
                deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, maximumOutputBytes: 4096, mergingStandardError: merging)
        }
        expectEqual(execute("echo out; echo problem >&2; exit 3"), .exited(status: 3, output: "out\nproblem\n"),
            "exit status with merged standard error")
        expectEqual(execute("echo out; echo problem >&2; exit 3", merging: false), .exited(status: 3, output: "out\n"),
            "exit status without standard error")
        expectEqual(execute("exit 0"), .exited(status: 0, output: ""), "clean exit")
        expectEqual(execute("kill -TERM $$"), .abnormal, "signalled execution")
        expectEqual(ClusterLinkToolProcess.execute(executable: "/nonexistent/darkbloom-link-tool", arguments: [],
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, maximumOutputBytes: 4096, mergingStandardError: true),
            .abnormal, "missing executable")
        expectEqual(ClusterLinkToolProcess.execute(executable: "/bin/sleep", arguments: ["30"],
            deadline: DispatchTime.now().uptimeNanoseconds + 300_000_000, maximumOutputBytes: 4096, mergingStandardError: true),
            .timedOut, "timed-out execution")
        expectEqual(ClusterLinkToolProcess.execute(executable: "/usr/bin/yes", arguments: [],
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, maximumOutputBytes: 4096, mergingStandardError: true),
            .outputTooLarge, "flooding execution")

        // Every pipe end is closed by the run that opened it, whether the child
        // exited, failed to start, timed out or overflowed.
        expectEqual(openDescriptors(), descriptorsBefore, "no run left a descriptor open")
    }
}

private extension ClusterLinkToolOutcome {
    /// `env` prints in an unspecified order.
    var sortedLines: ClusterLinkToolOutcome {
        guard case .output(let text) = self else { return self }
        return .output(text.split(separator: "\n").sorted().joined(separator: "\n"))
    }
}
