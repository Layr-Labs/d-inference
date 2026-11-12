import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterBootstrap

/// Model-free worker, using the ACTUAL closed native argument parser. No model
/// directory is opened. All produced token IDs are fabricated CPU fixture data.
@main struct NativeStandIn {
    static func main() throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let options = try WorkerConfiguration(arguments: Array(CommandLine.arguments.dropFirst()), now: now)
        guard let bootstrap = options.bootstrap else { throw QualificationFailure.invalid("CPU stand-in requires authenticated attachment") }
        let remaining = options.load.deadlineUptimeNanoseconds - now
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(UInt32((remaining + 999_999_999) / 1_000_000_000))
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("owner.json").path
        let (raw, _) = try readQualificationJSON(path, maximum: 16_384)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let encoded = object["readyTemplateBase64"] as? String else { throw QualificationFailure.invalid("Missing configured ready template") }
        let template = try qualificationTemplate(encoded), identity = options.load.identity, rank = options.load.rank
        guard identity.modelID == template.identity.modelID, identity.artifactSHA256 == template.identity.artifactSHA256,
              identity.configurationSHA256 == template.identity.configurationSHA256, identity.peers == template.identity.peers,
              rank == template.rank else { throw QualificationFailure.invalid("Arguments differ from configured stand-in identity") }
        let connection = try bootstrap.connect(epoch: identity.membershipEpoch, rank: rank)
        let parts = [Data([2, 0, 0, 0]), Data(repeating: UInt8(31 + rank), count: 64), Data([0, 0, 0, 0]), Data([0, 0, 0, 0])]
        for (index, bytes) in parts.enumerated() { _ = try connection.exchange(sequence: UInt64(index), contribution: bytes) }
        var session = try ClusterWorkerSession(identity: identity, rank: rank, profile: template.profile, executionPlanSHA256: template.executionPlanSHA256)
        var sequence: UInt64 = 0, requestID: UUID?, reservation: ClusterWorkerReservation?, selected = 0
        func emit(_ event: ClusterWorkerEvent) throws {
            let id: UUID?
            switch event { case .ready, .unavailable, .shutdownComplete: id = nil; default: id = requestID }
            let frame = ClusterWorkerEventFrame(membershipEpoch: identity.membershipEpoch, sequence: sequence, requestID: id, event: event)
            try session.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
            try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame)); sequence += 1
        }
        try emit(.ready(.init(identity: identity, rank: rank, profile: template.profile,
            executionPlanSHA256: template.executionPlanSHA256, requestCapacityBytes: template.requestCapacityBytes)))
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        while true {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw QualificationFailure.invalid("Stand-in pipe failed") }
            if count == 0 { try decoder.finish(); return }
            for line in try decoder.append(Data(buffer.prefix(count))) {
                let frame = try ClusterWorkerCodec.decodeCommand(line)
                try session.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
                switch frame.command {
                case .reserve(let r):
                    // This fixture intentionally qualifies exactly two generated
                    // tokens. The same controller can later request real O128.
                    guard r.outputCount == 2, r.stopTokenIDs.isEmpty else { throw QualificationFailure.invalid("CPU fixture requires output2 and no stop tokens") }
                    requestID = frame.requestID; reservation = r; selected = 0
                    try emit(.admitted(reservedBytes: min(r.capacityLimitBytes, template.requestCapacityBytes)))
                case .start:
                    if rank == 0 { try emit(.committedToken(ordinal: 0, tokenID: 9, committedTokens: reservation!.promptTokenIDs.count)); selected = 1 }
                    else { try emit(.finished(.length)); reservation = nil; try emit(.retired(.clean)) }
                case .tokenDecision(let ordinal, let decision):
                    guard decision == .proceed, ordinal == selected - 1 else { throw QualificationFailure.invalid("Unexpected CPU token decision") }
                    if selected == 2 { try emit(.finished(.length)); reservation = nil; try emit(.retired(.clean)) }
                    else { try emit(.committedToken(ordinal: 1, tokenID: 10, committedTokens: reservation!.promptTokenIDs.count + 1)); selected = 2 }
                case .cancel: try emit(.retired(.cancelled)); return
                case .shutdown: try emit(.shutdownComplete); return
                }
            }
        }
    }
}
