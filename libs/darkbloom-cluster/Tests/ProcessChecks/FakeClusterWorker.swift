import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterBootstrap

/// Model-free child used only by the pipe-owner CPU tests.
@main struct FakeClusterWorker {
    static func main() throws {
        guard [3, 9].contains(CommandLine.arguments.count), let rank = Int(CommandLine.arguments[1]), (0...1).contains(rank) else { exit(64) }
        let behavior = CommandLine.arguments[2]
        // A stand-in's own hard deadline: no check, passing or failing, leaves one behind.
        alarm(60)
        if behavior.hasPrefix("bootstrap") {
            guard CommandLine.arguments.count == 9, CommandLine.arguments[3] == "--bootstrap-socket-path",
                  CommandLine.arguments[5] == "--bootstrap-owner-pid", CommandLine.arguments[7] == "--bootstrap-deadline-uptime-nanoseconds",
                  let owner = Int32(CommandLine.arguments[6]), let deadline = UInt64(CommandLine.arguments[8]) else { exit(64) }
            let connection = try ClusterBootstrapConnection.connect(path: CommandLine.arguments[4], ownerProcessID: owner,
                identity: .init(membershipEpoch: fixtureIdentity.membershipEpoch, rank: rank), deadlineUptimeNanoseconds: deadline)
            let parts = [Data(behavior == "bootstrap-bad-length" ? [1, 0, 0, 0] : [2, 0, 0, 0]),
                Data(repeating: UInt8(rank + 1), count: 64), Data([0, 0, 0, 0]), Data([0, 0, 0, 0])]
            for (sequence, bytes) in parts.enumerated() { _ = try connection.exchange(sequence: UInt64(sequence), contribution: bytes) }
        }
        if behavior == "hang" { signal(SIGTERM, SIG_IGN) }
        // Retirement-policy stand-ins. A signalled exit is made visible as 99.
        if behavior == "exit-early" { exit(9) }
        if behavior == "startup-exit" { usleep(300_000); exit(123) }
        if behavior == "never-ready" { while true { pause() } }
        if behavior == "slow-exit" { signal(SIGTERM) { _ in _exit(99) } }
        var session = try ClusterWorkerSession(identity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan)
        var sequence: UInt64 = 0, requestID: UUID?, reservation: ClusterWorkerReservation?, selected = 0
        func emit(_ event: ClusterWorkerEvent) throws {
            let id: UUID?
            switch event { case .ready, .unavailable, .shutdownComplete: id = nil; default: id = requestID }
            let frame = ClusterWorkerEventFrame(membershipEpoch: fixtureIdentity.membershipEpoch, sequence: sequence, requestID: id, event: event)
            try session.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
            try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame)); sequence += 1
        }
        try emit(.ready(.init(identity: fixtureIdentity, rank: rank, profile: fixtureProfile,
            executionPlanSHA256: fixturePlan, requestCapacityBytes: behavior == "larger" ? 2048 : 1024)))
        // Neither reads its command stream again; "deaf" also ignores SIGTERM.
        if behavior == "deaf" { signal(SIGTERM, SIG_IGN) }
        if behavior == "deaf" || behavior == "deaf-term" { while true { pause() } }
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        while true {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            // A worker that needs three seconds to end itself after its stream closes.
            if count == 0 && behavior == "slow-exit" { usleep(3_000_000); exit(3) }
            // "stall": a rank that never commits a token, does not answer
            // `cancel`, and needs 1.5 s to end itself after its stream closes,
            // like a rank inside a collective whose peer has gone.
            if count == 0 && behavior == "stall" { usleep(1_500_000); exit(4) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; exit(74) }
            let bytes = Data(buffer.prefix(count))
            for line in try decoder.append(bytes) {
                let command = try ClusterWorkerCodec.decodeCommand(line)
                try session.accept(command, now: DispatchTime.now().uptimeNanoseconds)
                switch command.command {
                case .reserve(let value):
                    requestID = command.requestID; reservation = value; selected = 0
                    if let raw = ProcessInfo.processInfo.environment["TEST_MAX_DEADLINE"], let maximum = UInt64(raw),
                       value.deadlineUptimeNanoseconds > maximum { exit(65) }
                    if let raw = ProcessInfo.processInfo.environment["TEST_MIN_REMAINING"], let minimum = UInt64(raw),
                       value.deadlineUptimeNanoseconds < DispatchTime.now().uptimeNanoseconds + minimum { exit(66) }
                    if behavior == "slow-admit" { Thread.sleep(forTimeInterval: 0.3) }
                    if behavior == "refuse" { try emit(.refused(.capacity)) }
                    else { try emit(.admitted(reservedBytes: behavior == "larger" ? 1400 : 800)) }
                case .start:
                    if behavior == "hang" || behavior == "stall" { continue }
                    if behavior == "exit" { exit(7) }
                    if behavior == "delayed-exit" { usleep(250_000); exit(7) }
                    if behavior == "partial" { try FileHandle.standardOutput.write(contentsOf: Data("{\"kind\":".utf8)); exit(0) }
                    if behavior == "stderr" { try FileHandle.standardError.write(contentsOf: Data(repeating: 120, count: 1_100_000)); continue }
                    if rank == 1 {
                        let reason: ClusterWorkerFinishReason = reservation!.stopTokenIDs.contains(9) ? .eos
                            : behavior == "clean-stop" ? .clientStop : .length
                        try emit(.finished(reason)); try emit(.retired(.clean)); if behavior == "exhausted" { try emit(.unavailable(.runtimeError)) }
                    } else if behavior == "bad-sequence" || behavior == "bad-token" {
                        let frame = ClusterWorkerEventFrame(membershipEpoch: fixtureIdentity.membershipEpoch,
                            sequence: sequence + (behavior == "bad-sequence" ? 1 : 0), requestID: requestID,
                            event: .committedToken(ordinal: behavior == "bad-token" ? 1 : 0, tokenID: 9, committedTokens: reservation!.promptTokenIDs.count))
                        try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame))
                    } else {
                        try emit(.committedToken(ordinal: 0, tokenID: 9, committedTokens: reservation!.promptTokenIDs.count)); selected = 1
                    }
                case .tokenDecision(_, let decision):
                    let last = 8 + selected
                    let reason: ClusterWorkerFinishReason? = reservation!.stopTokenIDs.contains(last) ? .eos
                        : selected == reservation!.outputCount ? .length : decision == .cleanStop ? .clientStop : nil
                    // "batched": rank 0 of a phase-split pair as its owner sees it.
                    // Tokens after the first arrive in relayed batches of 1, 2, 4,
                    // 8 then 16 with a pause before each batch, and a client stop
                    // is answered only at the decoding rank's next batch boundary.
                    if behavior == "batched" {
                        if reason == .clientStop { usleep(250_000) }
                        else if reason == nil, [1, 3, 7, 15, 31].contains(selected) { usleep(80_000) }
                    }
                    if let reason { try emit(.finished(reason)); try emit(.retired(.clean)); if behavior == "exhausted" { try emit(.unavailable(.runtimeError)) } }
                    else {
                        try emit(.committedToken(ordinal: selected, tokenID: 9 + selected,
                            committedTokens: reservation!.promptTokenIDs.count + selected)); selected += 1
                    }
                case .cancel:
                    if behavior == "hang" || behavior == "stall" { continue }
                    try emit(.retired(.cancelled))
                case .shutdown:
                    // "slow-shutdown": releasing takes half a second. Status 21
                    // reports that the command stream was closed before the
                    // release was acknowledged.
                    if behavior == "slow-shutdown" {
                        usleep(500_000)
                        var probe = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                        if poll(&probe, 1, 0) > 0 { exit(21) }
                    }
                    try emit(.shutdownComplete); return
                }
            }
        }
        try decoder.finish()
    }
}
