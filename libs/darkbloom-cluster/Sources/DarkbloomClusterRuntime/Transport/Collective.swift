import Cmlx
import Foundation
import MLX

enum ClusterTransport: String {
    case jaccl
    case loopbackTest = "loopback-test"

    var backend: String { self == .jaccl ? "jaccl" : "ring" }
}

final class Collective {
    private var handle = mlx_distributed_group_new()
    let rank: Int
    let size: Int
    let transport: ClusterTransport
    private var tokenSequence: TokenSelectionSequence?
    private(set) var modelReductionCount = 0

    var transportLabel: String { transport.rawValue }
    var correctnessOnly: Bool { transport == .loopbackTest }

    static var jacclAvailable: Bool { mlx_distributed_is_available("jaccl") }

    init(transport: ClusterTransport = .jaccl, bootstrap: JACCLBootstrap? = nil) throws {
        guard bootstrap == nil || transport == .jaccl else {
            throw ProbeError("Owner bootstrap requires JACCL")
        }
        self.transport = transport
        let expectedRank: Int? = try transport == .loopbackTest ? Self.validateLoopback() : nil
        guard mlx_distributed_is_available(transport.backend) else {
            throw ProbeError("Requested \(transport.rawValue) backend is unavailable; no fallback is allowed")
        }
        if transport == .loopbackTest {
            log("Using loopback-test transport for correctness only; timings are not cluster-performance evidence")
        }
        var initialized = mlx_distributed_group_new()
        try MLX.withError { error in
            let status: Int32
            if let bootstrap {
                status = try bootstrap.initialize(&initialized)
            } else {
                status = mlx_distributed_init(&initialized, true, transport.backend)
            }
            try error.check()
            guard status == 0 else { throw ProbeError("\(transport.rawValue) initialization failed: \(status)") }
        }
        handle = initialized
        rank = Int(mlx_distributed_group_rank(initialized))
        size = Int(mlx_distributed_group_size(initialized))
        guard size == 2, (0..<size).contains(rank) else {
            throw ProbeError("FFN TP requires exactly two ranks, got rank=\(rank) size=\(size)")
        }
        if let expectedRank, rank != expectedRank {
            throw ProbeError("Loopback backend initialized an unexpected rank")
        }
    }

    deinit { mlx_distributed_group_free(handle) }

    func sum(_ input: MLXArray) -> MLXArray {
        // Control agreements and token selection are Int32. Count floating
        // model reductions separately to detect optimized-path hook bypasses.
        if [.float16, .bfloat16, .float32].contains(input.dtype) { modelReductionCount += 1 }
        var result = mlx_array_new()
        let status = mlx_distributed_all_sum(&result, input.ctx, handle, StreamOrDevice.cpu.ctx)
        precondition(status == 0, "\(transportLabel) all-sum graph construction failed")
        return MLXArray(result)
    }

    /// Serialized point-to-point completion; this is not a peer-consumed ACK.
    /// The returned Send handle aliases the input. Caller must not overlap MLX work.
    func sendCompleted(_ input: MLXArray, to peer: Int, maximumBytes: Int,
                       check: () throws -> Void) throws -> MLXArray {
        try withExtendedLifetime(self) {
            try CollectivePointToPoint.send(input, peer: peer, group: handle,
                rank: rank, size: size, maximumBytes: maximumBytes, check: check)
        }
    }

    /// Known-shape, exact-dtype receive with evaluated owned-storage admission.
    /// Validate the wire header first; a failed transfer fences the whole cohort.
    func receiveCompleted(shape: [Int], dtype: DType, from peer: Int, maximumBytes: Int,
                          check: () throws -> Void) throws -> MLXArray {
        try withExtendedLifetime(self) {
            try CollectivePointToPoint.receive(shape: shape, dtype: dtype, peer: peer,
                group: handle, rank: rank, size: size, maximumBytes: maximumBytes, check: check)
        }
    }

    func barrier() {
        let result = sum(MLXArray(Int32(rank + 1)))
        eval(result)
        precondition(result.item(Int32.self) == 3, "\(transportLabel) rank handshake failed")
    }

    /// Both ranks must execute the same shape and loop counts before a model graph is built.
    func requireAgreement(_ values: [Int32]) throws {
        let mine = MLXArray(values)
        let combined = sum(mine)
        eval(combined)
        guard combined.asArray(Int32.self) == values.map({ $0 * 2 }) else {
            throw ProbeError("Ranks disagree on the inference workload or model configuration")
        }
    }

    /// Explicitly reset at every warmup/repetition. The first selection verifies
    /// this identity with the peer in the same collective that carries its token.
    func beginTokenSequence(sequence: Int, vocabularySize: Int, outputCount: Int) {
        tokenSequence = TokenSelectionSequence(sequence: sequence, vocabularySize: vocabularySize,
                                               outputCount: outputCount)
    }

    func selectToken(localArgmax: Int, sequence: Int, step: Int) throws -> Int {
        var state = tokenSequence ?? TokenSelectionSequence(sequence: 0, vocabularySize: 0, outputCount: 0)
        let payload = state.payload(localArgmax: localArgmax, sequence: sequence, step: step, rank: rank)
        let combined = sum(MLXArray(payload))
        try MLX.withError { error in
            eval(combined)
            try error.check()
        }
        let token = try state.accept(combined.asArray(Int32.self), sequence: sequence, step: step)
        tokenSequence = state
        return token
    }

    /// The test backend may only open two IPv4 loopback listeners. Reject
    /// ambiguous hostnames, extra addresses, malformed ranks, and singleton groups.
    private static func validateLoopback() throws -> Int {
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
