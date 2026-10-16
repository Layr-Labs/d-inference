import CryptoKit
import Cmlx
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX

public enum ClusterTransport: String {
    case jaccl
    case loopbackTest = "loopback-test"
    /// Two ranks on one Mac over a 127.0.0.1 socket (`CollectiveLocalSocket`).
    /// Correctness only: point-to-point transfers, no reductions, never RDMA.
    case localSocketTest = "local-socket-test"

    var backend: String { self == .jaccl ? "jaccl" : "ring" }

    /// The transport a resident rank was launched for. Absence means JACCL;
    /// only the single-Mac qualification socket can be declared instead.
    static func admit(environment: [String: String]) throws -> Self {
        guard let value = environment[CollectiveLocalSocket.environmentName] else { return .jaccl }
        guard value == Self.localSocketTest.rawValue else {
            throw ProbeError("Unknown \(CollectiveLocalSocket.environmentName); only \(Self.localSocketTest.rawValue) can be declared")
        }
        return .localSocketTest
    }

    /// Extra load-agreement fields. JACCL's agreement bytes are unchanged.
    var loadAgreementFields: [String] {
        self == .jaccl ? [] : ["qwen-resident-transport-v1", rawValue]
    }
}

public final class Collective {
    private(set) var handle = mlx_distributed_group_new()
    public let rank: Int
    public let size: Int
    public let transport: ClusterTransport
    private var tokenSequence: TokenSelectionSequence?
    private(set) var modelReductionCount = 0
    private let localSocket: CollectiveLocalSocket?
    /// The keyed data plane (S16), once the pinned exchange confirmed. From
    /// then on every transfer between the ranks is an authenticated, encrypted
    /// record; nothing goes in the clear.
    private var protected: CollectiveAuthenticatedRecords?
    private var protectedIO: CollectiveRecordByteIO?
    /// Set as soon as a launch supplies a credential: a transfer before the
    /// exchange confirms, or one without a record scope, is refused.
    public private(set) var protectionRequired = false
    /// What the exchange established; nil for a plaintext data plane.
    public private(set) var dataPlane: ClusterDataPlaneReceipt?
    /// Tensor parallel only: the sealed all-sum's direction keys from the
    /// confirmed exchange, taken once by the codec (`takeTensorParallelSealKeys`).
    private var tensorParallelSealKeys: (send: SymmetricKey, receive: SymmetricKey)?
    /// The sealed all-sum's keys, once; nil when the data plane was not keyed for tensor parallel.
    func takeTensorParallelSealKeys() -> (send: SymmetricKey, receive: SymmetricKey)? {
        defer { tensorParallelSealKeys = nil }
        return tensorParallelSealKeys
    }

    public var transportLabel: String { transport.rawValue }
    public var correctnessOnly: Bool { transport != .jaccl }

    public static var jacclAvailable: Bool { mlx_distributed_is_available("jaccl") }

    /// JACCL is created through the owner's exchange when this worker
    /// installed one (`JACCLOwnerBootstrap`); otherwise JACCL opens its own
    /// coordinator socket (the direct native bootstrap). The two are never
    /// substituted for each other: an installed exchange is always used.
    public init(transport: ClusterTransport = .jaccl) throws {
        guard transport != .localSocketTest else {
            throw ProbeError("local-socket-test is created with its rank and loopback endpoint, not from a native backend")
        }
        self.transport = transport; localSocket = nil
        let expectedRank: Int? = try transport == .loopbackTest ? Self.validateLoopback() : nil
        guard mlx_distributed_is_available(transport.backend) else {
            throw ProbeError("Requested \(transport.rawValue) backend is unavailable; no fallback is allowed")
        }
        if transport == .loopbackTest {
            log("Using loopback-test transport for correctness only; timings are not cluster-performance evidence")
        }
        var initialized = mlx_distributed_group_new()
        let owner = transport == .jaccl ? JACCLOwnerBootstrap.take() : nil
        if let owner { log("JACCL bootstrap through the authenticated owner (rank \(owner.rank)); no coordinator socket is opened") }
        try MLX.withError { error in
            let status = owner.map { JACCLOwnerBootstrap.initialize(&initialized, rank: $0.rank, exchange: $0.exchange) }
                ?? mlx_distributed_init(&initialized, true, transport.backend)
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
        if let owner, rank != owner.rank {
            throw ProbeError("The owner bootstrap initialized another rank")
        }
    }

    /// The single-Mac qualification group: two ranks, point-to-point only, over
    /// a 127.0.0.1 socket. No native distributed backend is initialized.
    init(localSocketRank rank: Int, coordinator: String, progressTimeoutMilliseconds: Int,
         deadlineUptimeNanoseconds: UInt64) throws {
        log("Using local-socket-test transport for correctness only; this is not RDMA and its timings are not pair timings")
        localSocket = try CollectiveLocalSocket(rank: rank, coordinator: coordinator,
            progressTimeoutMilliseconds: progressTimeoutMilliseconds, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
        transport = .localSocketTest; self.rank = rank; size = 2
    }

    deinit { mlx_distributed_group_free(handle) }

    func sum(_ input: MLXArray) -> MLXArray {
        precondition(localSocket == nil, "local-socket-test carries point-to-point transfers only")
        // A reduction cannot be an authenticated record: a keyed data plane refuses it.
        precondition(!protectionRequired, "A keyed data plane carries authenticated point-to-point records only")
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
    /// On a keyed data plane `scope` is required and the array leaves as
    /// authenticated, encrypted records (the input itself is returned).
    public func sendCompleted(_ input: MLXArray, to peer: Int, maximumBytes: Int,
                              scope: CollectiveRecordScope? = nil, check: () throws -> Void) throws -> MLXArray {
        if let protected {
            guard peer == 1 - rank, let scope else {
                protected.invalidate()
                throw ProbeError("A keyed data plane refuses a transfer without its record scope")
            }
            try protected.sendArray(input, scope: scope, maximumBytes: maximumBytes, check: check)
            return input
        }
        guard !protectionRequired else {
            throw ProbeError("A data-plane transfer was attempted before the data plane was keyed")
        }
        return try rawSendCompleted(input, to: peer, maximumBytes: maximumBytes, check: check)
    }

    /// Known-shape, exact-dtype receive with evaluated owned-storage admission.
    /// Validate the wire header first; a failed transfer fences the whole cohort.
    public func receiveCompleted(shape: [Int], dtype: DType, from peer: Int, maximumBytes: Int,
                                 scope: CollectiveRecordScope? = nil, check: () throws -> Void) throws -> MLXArray {
        if let protected {
            guard peer == 1 - rank, let scope else {
                protected.invalidate()
                throw ProbeError("A keyed data plane refuses a transfer without its record scope")
            }
            return try protected.receiveArray(shape: shape, dtype: dtype, scope: scope, maximumBytes: maximumBytes, check: check)
        }
        guard !protectionRequired else {
            throw ProbeError("A data-plane transfer was attempted before the data plane was keyed")
        }
        return try rawReceiveCompleted(shape: shape, dtype: dtype, from: peer, maximumBytes: maximumBytes, check: check)
    }

    /// The native path itself: the hellos, then ciphertext frames only.
    func rawSendCompleted(_ input: MLXArray, to peer: Int, maximumBytes: Int,
                          check: () throws -> Void) throws -> MLXArray {
        try withExtendedLifetime(self) {
            if let localSocket {
                guard peer == 1 - rank else { throw ProbeError("Point-to-point transfer requires the other rank of a two-rank group") }
                return try localSocket.send(input, maximumBytes: maximumBytes, check: check)
            }
            return try CollectivePointToPoint.send(input, peer: peer, group: handle,
                rank: rank, size: size, maximumBytes: maximumBytes, check: check)
        }
    }

    func rawReceiveCompleted(shape: [Int], dtype: DType, from peer: Int, maximumBytes: Int,
                             check: () throws -> Void) throws -> MLXArray {
        try withExtendedLifetime(self) {
            if let localSocket {
                guard peer == 1 - rank else { throw ProbeError("Point-to-point transfer requires the other rank of a two-rank group") }
                return try localSocket.receive(shape: shape, dtype: dtype, maximumBytes: maximumBytes, check: check)
            }
            return try CollectivePointToPoint.receive(shape: shape, dtype: dtype, peer: peer,
                group: handle, rank: rank, size: size, maximumBytes: maximumBytes, check: check)
        }
    }

    /// The data plane's keys (S16, D1): exchange signed hellos on the raw path,
    /// verify the peer's against the identity this rank pins before deriving
    /// anything, confirm the keys, then carry every later transfer as records.
    /// `scopeSHA256` is the load agreement both ranks are about to compare.
    /// Called once, right after the group exists and before any other transfer.
    public func establishDataPlane(credential: ClusterDataPlaneCredential, scopeSHA256: Data,
                                   tamper: CollectiveRecordTamper? = nil,
                                   rekey: ClusterRecordRekeyPolicy = .dataPlane,
                                   tensorParallelSeal: Bool = false,
                                   check: () throws -> Void) throws -> ClusterDataPlaneReceipt {
        guard protected == nil, dataPlane == nil, size == 2, credential.rank == rank else {
            throw ProbeError("The data plane is keyed once, by this rank's own credential")
        }
        protectionRequired = true
        let exchange = try ClusterDataPlaneKeyExchange(credential: credential, scopeSHA256: scopeSHA256)
        // Rank 0 sends first; both send before either judges what it received.
        func swap(_ mine: Data) throws -> Data {
            func send() throws {
                try withExtendedLifetime(mine) {
                    _ = try rawSendCompleted(MLXArray(mine, [mine.count], type: UInt8.self), to: 1 - rank,
                        maximumBytes: mine.count, check: check)
                }
            }
            func receive() throws -> Data {
                let array = try rawReceiveCompleted(shape: [mine.count], dtype: .uint8, from: 1 - rank,
                    maximumBytes: mine.count, check: check)
                let copied = array.asData(access: .copy)
                guard copied.data.count == mine.count else { throw ProbeError("Data-plane hello size differs") }
                return copied.data
            }
            if rank == 0 { try send(); return try receive() }
            let value = try receive(); try send(); return value
        }
        do {
            let tag = try exchange.accept(peerHello: try swap(exchange.hello))
            try exchange.confirm(peerTag: try swap(tag))
            // Tensor parallel: the sealed all-sum's direction keys, from this
            // confirmed session and its scope (before the record master goes).
            if tensorParallelSeal { tensorParallelSealKeys = try exchange.tensorParallelSealKeys(scope: scopeSHA256) }
            let limits = try ClusterRecordLimits(maximumPlaintextBytes: CollectiveAuthenticatedRecords.chunkBytes)
            let io = try CollectiveRecordByteIO(collective: self,
                maximumFrameBytes: limits.maximumPlaintextBytes + ClusterRecordTransferAccounting.framingBytes,
                tamper: tamper)
            let (transport, receipt) = try exchange.makeTransport(io: io, limits: limits, rekey: rekey)
            protected = try CollectiveAuthenticatedRecords(transport: transport, io: io)
            protectedIO = io; dataPlane = receipt
            log("darkbloom-data-plane-v1 rank=\(rank) protection=\(ClusterWorkerDataPlane.encrypted) peer_verified=1"
                + " transcript=\(receipt.transcriptHex) edge=\(receipt.edgeHex) record_bytes=\(limits.maximumPlaintextBytes)"
                + " rekey_records=\(rekey.records) rekey_bytes=\(rekey.bytes) rekey_seconds=\(rekey.seconds)")
            return receipt
        } catch {
            exchange.invalidate()
            throw ProbeError("Data-plane key exchange failed: \(error)")
        }
    }

    /// The readiness record's data-plane field.
    public var workerDataPlane: ClusterWorkerDataPlane? {
        dataPlane.map { .init(protection: ClusterWorkerDataPlane.encrypted, peerVerified: $0.peerVerified,
                              transcriptSHA256: $0.transcriptHex, edgeID: $0.edgeHex) }
    }

    /// Records sealed and opened and the key generations in use.
    public var dataPlaneStatus: ClusterRecordTransportStatus? { protected?.status }

    /// One line with what the keyed data plane carried in this session, for
    /// the launcher's evidence: records and plaintext bytes each way and the
    /// key generation each direction reached. Nothing for a plaintext plane.
    public func logDataPlaneStatus() {
        guard let status = dataPlaneStatus else { return }
        log("darkbloom-data-plane-status-v1 rank=\(rank) " + status.lineFields)
    }

    /// Fail closed at once: later transfers refuse.
    public func invalidateDataPlane() { protected?.invalidate() }

    public func barrier() {
        let result = sum(MLXArray(Int32(rank + 1)))
        eval(result)
        precondition(result.item(Int32.self) == 3, "\(transportLabel) rank handshake failed")
    }

    /// Both ranks must execute the same shape and loop counts before a model graph is built.
    public func requireAgreement(_ values: [Int32]) throws {
        let mine = MLXArray(values)
        let combined = sum(mine)
        eval(combined)
        guard combined.asArray(Int32.self) == values.map({ $0 * 2 }) else {
            throw ProbeError("Ranks disagree on the inference workload or model configuration")
        }
    }

    /// Explicitly reset at every warmup/repetition. The first selection verifies
    /// this identity with the peer in the same collective that carries its token.
    public func beginTokenSequence(sequence: Int, vocabularySize: Int, outputCount: Int) {
        tokenSequence = TokenSelectionSequence(sequence: sequence, vocabularySize: vocabularySize,
                                               outputCount: outputCount)
    }

    public func selectToken(localArgmax: Int, sequence: Int, step: Int) throws -> Int {
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
