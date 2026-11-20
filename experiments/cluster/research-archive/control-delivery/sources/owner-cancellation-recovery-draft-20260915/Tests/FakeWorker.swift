import Foundation
import Darwin
import DarkbloomClusterProtocol

/// Actual local pipe child, no model/MLX/network. Abnormal cancellation emits
/// failed then exits; it deliberately does NOT fabricate a native retired event.
@main struct FakeWorker {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, let rank = Int(args[1]), (0...1).contains(rank), let epoch = UUID(uuidString: args[3]) else { exit(64) }
        let behavior = args[2], identity = fixtureIdentity(epoch)
        let fd = Darwin.open(args[4], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { exit(73) }; defer { Darwin.close(fd) }
        var selected = 0, active = false, requestID: UUID?, reservation: ClusterWorkerReservation?, sequence: UInt64 = 0
        var session = try ClusterWorkerSession(identity: identity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan)
        func log(_ event: String) throws {
            var bytes = try JSONSerialization.data(withJSONObject: ["event": event, "rank": rank, "active": active,
                "selected": selected, "epoch": epoch.uuidString.lowercased(), "uptime": DispatchTime.now().uptimeNanoseconds], options: .sortedKeys)
            bytes.append(10)
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw QualificationFailure.invalid("Fixture log write failed") }; offset += count
                }
            }
        }
        func emit(_ event: ClusterWorkerEvent) throws {
            let id: UUID?
            switch event { case .ready, .shutdownComplete, .unavailable: id = nil; default: id = requestID }
            let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: sequence, requestID: id, event: event)
            try session.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
            try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame)); sequence += 1
        }
        func token() throws {
            let token = behavior == "wrong-recovery" ? 1 : 9 + selected
            try emit(.committedToken(ordinal: selected, tokenID: token, committedTokens: reservation!.promptTokenIDs.count + selected))
            selected += 1
        }
        try emit(.ready(.init(identity: identity, rank: rank, profile: fixtureProfile,
            executionPlanSHA256: fixturePlan, requestCapacityBytes: 1024)))
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        while true {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { break }; if count < 0 && errno == EINTR { continue }; guard count > 0 else { exit(74) }
            for line in try decoder.append(Data(bytes.prefix(count))) {
                let command = try ClusterWorkerCodec.decodeCommand(line)
                try session.accept(command, now: DispatchTime.now().uptimeNanoseconds)
                switch command.command {
                case .reserve(let value): requestID = command.requestID; reservation = value; try emit(.admitted(reservedBytes: 800))
                case .start:
                    active = true; try log("start")
                    if rank == 0 && behavior != "before-first" { try token() }
                    if rank == 1 && ["recovery", "wrong-recovery", "fast"].contains(behavior) {
                        try emit(.finished(.length)); try emit(.retired(.clean)); active = false
                    }
                case .tokenDecision:
                    if selected == 128 {
                        try emit(.finished(.length)); try emit(.retired(.clean)); active = false; try log("finished")
                    } else { try token() }
                case .cancel:
                    try log("cancel")
                    try emit(.failed(.callerCancelled)); active = false; try log("exit-after-cancel"); exit(17)
                case .shutdown:
                    try log("shutdown"); try emit(.shutdownComplete); return
                }
            }
        }
        try decoder.finish()
    }
}
