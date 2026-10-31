import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterBootstrap

/// CPU-only direct child: deliberately never prints its input credential.
@main struct CalibrationFixture {
    static func main() {
        do { try run() } catch { exit(69) }
    }
    private static func run() throws {
        let args = CommandLine.arguments
        let mode = args[1], reportPath = args[2], control = args[3]
        let epoch = UUID(uuidString: args[4])!, deadline = UInt64(args[5])!
        signal(SIGPIPE, SIG_IGN)
        if mode == "stubborn" || mode == "blocked-input" { signal(SIGTERM, SIG_IGN) }
        if mode == "blocked-input" { while true { usleep(10000) } }
        var first = Data()
        while first.last != 10 {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { exit(65) }
            first.append(byte); if first.count > 4096 { exit(66) }
        }
        let credential = try ClusterWorkerCodec.decodeDataPlaneTrust(first)
        guard credential.membershipEpoch == epoch, credential.rank == 0 else { exit(67) }
        try Data("credential".utf8).write(to: URL(fileURLWithPath: control + ".credential"))
        if mode.hasPrefix("bootstrap") {
            let extra = Array(args.dropFirst(6))
            let connection = try ClusterBootstrapConnection.connect(path: extra[1], ownerProcessID: Int32(extra[3])!,
                identity: .init(membershipEpoch: epoch, rank: 0), deadlineUptimeNanoseconds: UInt64(extra[5])!)
            for (i, bytes) in [Data([2,0,0,0]), Data(repeating: 1, count: 64), Data([0,0,0,0]), Data([0,0,0,0])].enumerated() {
                _ = try connection.exchange(sequence: UInt64(i), contribution: bytes)
            }
            connection.cancel()
        }
        let report = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        if mode.hasPrefix("closed-input-") && mode != "closed-input-after-renewal" {
            // Actual kernel EPIPE: read/validate the real credential above, emit
            // all/some/no report, then close only stdin while this child stays alive.
            let split = report.count / 2
            if mode == "closed-input-delayed-report" || mode == "closed-input-partial" {
                FileHandle.standardOutput.write(Data(report.prefix(split)))
            } else if mode != "closed-input-no-report" {
                FileHandle.standardOutput.write(report + Data([10]))
                if mode == "closed-input-multiple" {
                    FileHandle.standardOutput.write(report + Data([10]))
                }
            }
            if mode == "closed-input-stubborn" { signal(SIGTERM, SIG_IGN) }
            guard close(STDIN_FILENO) == 0 else { exit(70) }
            try Data("actual-stdin-closed".utf8).write(
                to: URL(fileURLWithPath: control + ".input-closed"))
            if mode == "closed-input-eof" { close(STDOUT_FILENO); close(STDERR_FILENO) }
            while !FileManager.default.fileExists(atPath: control + ".release") {
                if mode != "closed-input-stubborn" && DispatchTime.now().uptimeNanoseconds >= deadline {
                    exit(124)
                }
                usleep(1000)
            }
            if mode == "closed-input-delayed-report" {
                FileHandle.standardOutput.write(Data(report.dropFirst(split)) + Data([10]))
            }
            exit(mode == "closed-input-nonzero" ? 9 : 0)
        }
        if mode != "no-report" && mode != "stubborn" {
            if mode == "oversize" { FileHandle.standardOutput.write(Data(repeating: 65, count: 70_000)) }
            else { FileHandle.standardOutput.write(report + Data([10])) }
            if mode == "multiple" { FileHandle.standardOutput.write(report + Data([10])) }
        }
        if mode == "stderr-flood" { FileHandle.standardError.write(Data(repeating: 65, count: (1 << 20) + 8192)) }
        if mode == "eof-live" { close(STDOUT_FILENO); close(STDERR_FILENO) }
        if mode == "exit" || mode == "bootstrap" { exit(0) }
        if mode == "nonzero" { exit(9) }
        _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
        var pending = Data(), renewals: UInt64 = 0
        while true {
            if FileManager.default.fileExists(atPath: control + ".release") { exit(0) }
            if mode != "stubborn" && mode != "eof-live" && DispatchTime.now().uptimeNanoseconds >= deadline { exit(124) }
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            _ = poll(&fd, 1, 10)
            if fd.revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let n = read(STDIN_FILENO, &bytes, bytes.count)
                if n == 0 {
                    if mode != "stubborn" && mode != "eof-live" { exit(0) }
                    usleep(10000)
                } else if n > 0 {
                    pending.append(contentsOf: bytes.prefix(n))
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[...newline]); pending.removeSubrange(...newline)
                        guard case .extendDeadline(let renewal) = try ClusterWorkerCodec.decodeControl(line),
                              renewal.membershipEpoch == epoch, renewal.renewal == renewals + 1 else { exit(68) }
                        renewals = renewal.renewal
                        try Data(String(renewals).utf8).write(to: URL(fileURLWithPath: control + ".renewals"), options: .atomic)
                        if mode == "closed-input-after-renewal" {
                            // Witness a real successfully decoded grant before closing input.
                            let receivedAt = DispatchTime.now().uptimeNanoseconds
                            guard close(STDIN_FILENO) == 0 else { exit(70) }
                            let closedAt = DispatchTime.now().uptimeNanoseconds
                            let receipt: [String: Any] = ["renewal": renewals,
                                "ttlNanoseconds": renewal.ttlNanoseconds,
                                "receivedAtUptimeNanoseconds": receivedAt,
                                "closedAtUptimeNanoseconds": closedAt]
                            try JSONSerialization.data(withJSONObject: receipt).write(
                                to: URL(fileURLWithPath: control + ".input-closed"), options: .atomic)
                            while !FileManager.default.fileExists(atPath: control + ".release") {
                                guard DispatchTime.now().uptimeNanoseconds < deadline else { exit(124) }
                                usleep(1000)
                            }
                            exit(0)
                        }
                    }
                }
            }
        }
    }
}
