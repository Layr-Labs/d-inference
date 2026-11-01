import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// Real child pipes and real owner/pair admission. Child READY is fabricated:
/// this is no evidence of a native model, keyed handshake, or MTP execution.
@main struct TensorAssistantReadinessCheck {
    static let identity = ClusterWorkerIdentity(membershipEpoch: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
        modelID: ClusterQwenTensorAssistantPolicy.runtimeModelID, artifactSHA256: String(repeating: "a", count: 64),
        configurationSHA256: String(repeating: "b", count: 64), peers: [
            .init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
            .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
    static let profile = ClusterWorkerProfile(id: "registered_qwen38_27b_greedy_generation_v1", vocabularySize: 248320,
        maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumChunkTokens: 512, maximumContextTokens: 65536)
    static let plan = String(repeating: "e", count: 64)
    struct Failure: Error { let message: String }
    static func require(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func observation(depth: Int, capacity: Int) throws -> ClusterQwenTensorAssistantReady? {
        if depth == 0 { return nil }
        return try .init(policy: .init(depth: depth, inventorySHA256: String(repeating: "f", count: 64)), capacity: capacity)
    }
    static func child() throws {
        alarm(15)
        let rank = Int(CommandLine.arguments[2])!, depth = Int(CommandLine.arguments[3])!, capacity = Int(CommandLine.arguments[4])!
        let value = try observation(depth: depth, capacity: capacity)
        var sequence: UInt64 = 0
        func emit(_ event: ClusterWorkerEvent) throws {
            try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(.init(membershipEpoch: identity.membershipEpoch,
                sequence: sequence, requestID: nil, event: event)))
            sequence += 1
        }
        let plane = ClusterWorkerDataPlane(protection: ClusterWorkerDataPlane.encrypted, peerVerified: true,
            transcriptSHA256: String(repeating: "1", count: 64), edgeID: String(repeating: "2", count: 32))
        try emit(.ready(.init(identity: identity, rank: rank, profile: profile, executionPlanSHA256: plan,
            requestCapacityBytes: 4096, dataPlane: plane, media: ClusterQwenMedia.contract, tensorAssistant: value)))
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        while true {
            let bytes = FileHandle.standardInput.availableData
            if bytes.isEmpty { return }
            for line in try decoder.append(bytes) {
                guard case .command(let frame) = try ClusterWorkerCodec.decodeControl(line) else { continue }
                switch frame.command {
                case .shutdown: try emit(.shutdownComplete); return
                case .keepWarm(let ordinal): try emit(.keptWarm(ordinal: ordinal, microseconds: 1, servingContextTokens: nil))
                default: throw Failure(message: "Readiness child received request work")
                }
            }
        }
    }
    static func scenario(actual: [Int], expected: [Int], capacities: [Int] = [4, 4], lanes: Int = 4, succeeds: Bool) async throws {
        let now = DispatchTime.now().uptimeNanoseconds, deadline = now + 3_000_000_000
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let workers = try (0..<2).map { rank in
            try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: ["--child", String(rank), String(actual[rank]), String(capacities[rank])], environment: [:]),
                expectedIdentity: identity, rank: rank, profile: profile, executionPlanSHA256: plan,
                startupDeadline: deadline, initialLeaseDeadline: now + 5_000_000_000,
                expectedTensorAssistant: observation(depth: expected[rank], capacity: capacities[rank]))
        }
        defer { for worker in workers { worker.fence() } }
        var pair: ClusterWorkerPair?
        do {
            for worker in workers { try worker.launch() }
            pair = try .init(workers: workers, startupDeadline: deadline, lanes: lanes)
        } catch { if succeeds { throw error } }
        if succeeds {
            let ready = pair?.readiness
            try require(ready?.tensorAssistant == observation(depth: actual[0], capacity: capacities[0]), "Pair lost exact actual observation")
            try require(ready != nil, "Pair published no readiness")
        } else { try require(pair == nil, "Mismatched assistant became an admitted pair") }
        if let pair { await pair.shutdown() }
        for worker in workers { worker.fence() }
        let reap = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
        while !workers.allSatisfy(\.observedExit), DispatchTime.now().uptimeNanoseconds < reap {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(workers.allSatisfy(\.observedExit), "Child retirement was not observed")
    }
    static func main() async throws {
        if CommandLine.arguments.count > 1 { try child(); return }
        try await scenario(actual: [2, 2], expected: [2, 2], succeeds: true)
        try await scenario(actual: [0, 0], expected: [0, 0], succeeds: true)
        try await scenario(actual: [2, 2], expected: [0, 0], succeeds: false)
        try await scenario(actual: [0, 0], expected: [2, 2], succeeds: false)
        try await scenario(actual: [3, 3], expected: [2, 2], succeeds: false)
        try await scenario(actual: [2, 3], expected: [2, 3], succeeds: false)
        try await scenario(actual: [2, 2], expected: [2, 2], capacities: [4, 2], succeeds: false)
        try await scenario(actual: [2, 2], expected: [2, 2], lanes: 2, succeeds: false)
        print("{\"passed\":true,\"groups\":8,\"actualOwnedChildIO\":true,\"modelExecution\":false}")
    }
}
