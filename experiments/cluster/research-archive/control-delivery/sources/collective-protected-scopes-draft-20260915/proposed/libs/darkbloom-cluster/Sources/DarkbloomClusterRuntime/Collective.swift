import Cmlx
import Foundation
import MLX
import DarkbloomClusterSecurity

enum ClusterTransport: String {
    case jaccl
    case loopbackTest = "loopback-test"

    var backend: String { self == .jaccl ? "jaccl" : "ring" }
}

/// The facade owns one native group and, optionally, one session-global codec.
/// Scoped views retain that same owner; the raw endpoint is never exposed.
final class Collective {
    private let endpoint: CollectiveNativeEndpoint
    private let protectedSession: CollectiveProtectedSession?
    private let scope: CollectiveOperationScope?
    private var tokenSequence: TokenSelectionSequence?
    private(set) var modelReductionCount = 0
    var rank: Int { endpoint.rank }
    var size: Int { endpoint.size }
    var transport: ClusterTransport { endpoint.transport }
    var transportLabel: String { transport.rawValue }
    var correctnessOnly: Bool { transport == .loopbackTest }
    var requiresProtection: Bool { protectedSession != nil }
    var protectedStatus: ClusterRecordTransportStatus? { protectedSession?.status }
    static var jacclAvailable: Bool { mlx_distributed_is_available("jaccl") }

    init(transport: ClusterTransport = .jaccl, bootstrap: JACCLBootstrap? = nil) throws {
        endpoint = try .init(transport: transport, bootstrap: bootstrap)
        protectedSession = nil; scope = nil
    }

    /// Not selected by serving. Refuses before group creation until the exact
    /// measured staging profile and outer resource join are implemented.
    static func protected(transport: ClusterTransport = .jaccl, bootstrap: JACCLBootstrap? = nil,
                          configuration: CollectiveProtectionConfiguration) throws -> Collective {
        try configuration.resourcePolicy.requireQualified()
        let endpoint = try CollectiveNativeEndpoint(transport: transport, bootstrap: bootstrap)
        let session = try CollectiveProtectedSession(configuration: configuration,
            io: endpoint.recordIO(maximumFrameBytes: configuration.maximumFrameBytes))
        return .init(endpoint: endpoint, protectedSession: session, scope: nil)
    }

    private init(endpoint: CollectiveNativeEndpoint, protectedSession: CollectiveProtectedSession,
                 scope: CollectiveOperationScope?) {
        self.endpoint = endpoint; self.protectedSession = protectedSession; self.scope = scope
    }

    /// The closure is not evaluated on the qualified plaintext path. No mutable
    /// current-request/phase field can race a retained lookahead boundary.
    func scoped(_ makeScope: () throws -> CollectiveOperationScope) throws -> Collective {
        guard let protectedSession else { return self }
        do {
            let scope = try makeScope(); try scope.requireBinding(protectedSession.binding)
            guard protectedSession.status.active else { throw ProbeError("Protected native session is inactive") }
            return .init(endpoint: endpoint, protectedSession: protectedSession, scope: scope)
        } catch { protectedSession.invalidate(); throw error }
    }

    func invalidateProtection() { protectedSession?.invalidate() }

    func part(_ part: CollectiveOperationScope.Part) throws -> Collective {
        try scoped {
            guard let scope else { throw ProbeError("Protected sub-operation requires its immutable parent scope") }
            return try scope.part(part)
        }
    }

    func sendCompleted(_ input: MLXArray, to peer: Int, maximumBytes: Int,
                       check: () throws -> Void) throws -> MLXArray {
        guard let protectedSession else {
            return try endpoint.sendCompleted(input, peer: peer, maximumBytes: maximumBytes, check: check)
        }
        do {
            guard peer == 1 - rank, let scope else { throw ProbeError("Protected send requires its exact scoped peer operation") }
            let shape = try CollectivePointToPointShape(shape: input.shape, dtype: input.dtype, maximumBytes: maximumBytes)
            try shape.validateMetadata(input)
            try protectedSession.send(input, scope: scope.part(.array), check: check)
            // Ciphertext completed; this retained source alias is not a consumed ACK.
            return input
        } catch { protectedSession.invalidate(); throw error }
    }

    func receiveCompleted(shape: [Int], dtype: DType, from peer: Int, maximumBytes: Int,
                          check: () throws -> Void) throws -> MLXArray {
        guard let protectedSession else {
            return try endpoint.receiveCompleted(shape: shape, dtype: dtype, peer: peer, maximumBytes: maximumBytes, check: check)
        }
        do {
            guard peer == 1 - rank, let scope else { throw ProbeError("Protected receive requires its exact scoped peer operation") }
            _ = try CollectivePointToPointShape(shape: shape, dtype: dtype, maximumBytes: maximumBytes)
            return try protectedSession.receive(shape: shape, dtype: dtype, scope: scope.part(.array), check: check)
        } catch { protectedSession.invalidate(); throw error }
    }

    private func requirePlaintextCollective() throws {
        guard protectedSession == nil else {
            protectedSession?.invalidate()
            throw ProbeError("Raw collective reductions are forbidden by required record protection")
        }
    }

    func sum(_ input: MLXArray) throws -> MLXArray {
        try requirePlaintextCollective()
        if [.float16, .bfloat16, .float32].contains(input.dtype) { modelReductionCount += 1 }
        return try endpoint.sum(input)
    }

    func barrier() throws {
        let result = try sum(MLXArray(Int32(rank + 1)))
        eval(result)
        guard result.item(Int32.self) == 3 else { throw ProbeError("\(transportLabel) rank handshake failed") }
    }

    func requireAgreement(_ values: [Int32]) throws {
        let combined = try sum(MLXArray(values)); eval(combined)
        guard combined.asArray(Int32.self) == values.map({ $0 * 2 }) else {
            throw ProbeError("Ranks disagree on the inference workload or model configuration")
        }
    }

    func beginTokenSequence(sequence: Int, vocabularySize: Int, outputCount: Int) throws {
        try requirePlaintextCollective()
        tokenSequence = TokenSelectionSequence(sequence: sequence, vocabularySize: vocabularySize, outputCount: outputCount)
    }

    func selectToken(localArgmax: Int, sequence: Int, step: Int) throws -> Int {
        try requirePlaintextCollective()
        var state = tokenSequence ?? TokenSelectionSequence(sequence: 0, vocabularySize: 0, outputCount: 0)
        let payload = state.payload(localArgmax: localArgmax, sequence: sequence, step: step, rank: rank)
        let combined = try sum(MLXArray(payload))
        try MLX.withError { error in eval(combined); try error.check() }
        let token = try state.accept(combined.asArray(Int32.self), sequence: sequence, step: step)
        tokenSequence = state; return token
    }

    /// The test backend may only open two IPv4 loopback listeners. Reject
    /// ambiguous hostnames, extra addresses, malformed ranks, and singleton groups.
    fileprivate static func validateLoopback() throws -> Int {
        let environment = ProcessInfo.processInfo.environment
        guard let rankText = environment["MLX_RANK"], ["0", "1"].contains(rankText),
            let file = environment["MLX_HOSTFILE"], !file.isEmpty
        else { throw ProbeError("loopback-test requires MLX_RANK=0|1 and MLX_HOSTFILE") }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let hosts = try JSONDecoder().decode([[String]].self, from: data)
        guard hosts.count == 2, hosts.allSatisfy({ $0.count == 1 }) else {
            throw ProbeError("loopback-test requires exactly two ranks with one address each")
        }
        var ports = Set<Int>()
        for host in hosts {
            let parts = host[0].split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "127.0.0.1",
                !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                let port = Int(parts[1]), (1...65535).contains(port),
                ports.insert(port).inserted
            else { throw ProbeError("loopback-test addresses must be distinct 127.0.0.1:port endpoints") }
        }
        return Int(rankText)!
    }
}

/// Only this file can create or use raw native group operations. Record IO
/// retains this endpoint directly, never the protected facade.
private final class CollectiveNativeEndpoint: CollectiveCiphertextEndpoint {
    private let handle: mlx_distributed_group
    let rank: Int
    let size: Int
    let transport: ClusterTransport

    init(transport: ClusterTransport, bootstrap: JACCLBootstrap?) throws {
        guard bootstrap == nil || transport == .jaccl else { throw ProbeError("Owner bootstrap requires JACCL") }
        let expectedRank = try transport == .loopbackTest ? Collective.validateLoopback() : nil
        guard mlx_distributed_is_available(transport.backend) else {
            throw ProbeError("Requested \(transport.rawValue) backend is unavailable; no fallback is allowed")
        }
        if transport == .loopbackTest {
            log("Using loopback-test transport for correctness only; timings are not cluster-performance evidence")
        }
        var initialized = mlx_distributed_group_new()
        var transferred = false
        defer { if !transferred { mlx_distributed_group_free(initialized) } }
        try MLX.withError { error in
            let status: Int32
            if let bootstrap { status = try bootstrap.initialize(&initialized) }
            else { status = mlx_distributed_init(&initialized, true, transport.backend) }
            try error.check()
            guard status == 0 else { throw ProbeError("\(transport.rawValue) initialization failed: \(status)") }
        }
        let rank = Int(mlx_distributed_group_rank(initialized)), size = Int(mlx_distributed_group_size(initialized))
        guard size == 2, (0..<size).contains(rank) else { throw ProbeError("Collective requires exactly two ranks") }
        guard expectedRank == nil || rank == expectedRank else { throw ProbeError("Loopback backend initialized an unexpected rank") }
        self.transport = transport; self.rank = rank; self.size = size; handle = initialized; transferred = true
    }

    deinit { mlx_distributed_group_free(handle) }

    func sum(_ input: MLXArray) throws -> MLXArray {
        var result = mlx_array_new()
        var transferred = false
        defer { if !transferred { mlx_array_free(result) } }
        let status = mlx_distributed_all_sum(&result, input.ctx, handle, StreamOrDevice.cpu.ctx)
        guard status == 0 else { throw ProbeError("Raw all-sum graph construction failed") }
        transferred = true; return MLXArray(result)
    }

    func sendCompleted(_ input: MLXArray, peer: Int, maximumBytes: Int, check: () throws -> Void) throws -> MLXArray {
        try withExtendedLifetime(self) {
            try CollectivePointToPoint.send(input, peer: peer, group: handle, rank: rank, size: size,
                maximumBytes: maximumBytes, check: check)
        }
    }
    func receiveCompleted(shape: [Int], dtype: DType, peer: Int, maximumBytes: Int,
                          check: () throws -> Void) throws -> MLXArray {
        try withExtendedLifetime(self) {
            try CollectivePointToPoint.receive(shape: shape, dtype: dtype, peer: peer, group: handle,
                rank: rank, size: size, maximumBytes: maximumBytes, check: check)
        }
    }
    func sendCiphertextFrame(_ input: MLXArray, maximumBytes: Int, check: () throws -> Void) throws {
        _ = try sendCompleted(input, peer: 1 - rank, maximumBytes: maximumBytes, check: check)
    }
    func receiveCiphertextFrame(byteCount: Int, check: () throws -> Void) throws -> MLXArray {
        try receiveCompleted(shape: [byteCount], dtype: .uint8, peer: 1 - rank,
            maximumBytes: byteCount, check: check)
    }
    func recordIO(maximumFrameBytes: Int) throws -> CollectiveRecordByteIO {
        try .init(endpoint: self, maximumFrameBytes: maximumFrameBytes)
    }
}
