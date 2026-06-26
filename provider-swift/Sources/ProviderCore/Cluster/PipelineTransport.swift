/// PipelineTransport -- the wire over which sealed activation frames move
/// between ring neighbors during a pipeline forward pass.
///
/// Abstracted so the *securing* logic (seal/serialize/open/deserialize) is
/// tested independently of the *physical* transport:
///   - `LoopbackPipelineTransport` runs both ranks in one process (a buffer per
///     direction). Lets the full encode → seal → transfer → open → decode chain
///     be verified on ONE machine, today.
///   - `MLXRingTransport` (Spike A, on hardware) sends the sealed ciphertext
///     bytes between two Macs via the `MLXDistributed` ring binding.
///
/// IMPORTANT: the transport only ever sees ciphertext. Sealing happens above it
/// (`PipelineRunner`), so a tap on the real ring observes only AEAD frames.

import Foundation

public protocol PipelineTransport: Sendable {
    /// Send an already-sealed frame to the given peer rank.
    func send(_ sealedFrame: Data, to peerRank: Int) async throws
    /// Receive the next sealed frame from the given peer rank (FIFO per peer).
    func recv(from peerRank: Int) async throws -> Data
}

public enum PipelineTransportError: Error, Sendable {
    case closed
    case noPeer(rank: Int)
}

/// In-process transport: an ordered async queue per (fromRank → toRank) edge.
/// Two `LoopbackPipelineTransport` views over a shared `Mailbox` let two
/// in-process ranks exchange frames as if cabled together.
public actor LoopbackMailbox {
    // queues[from][to] = ordered frames in flight on that directed edge
    private var queues: [Int: [Int: [Data]]] = [:]
    private var waiters: [Int: [Int: [CheckedContinuation<Data, Error>]]] = [:]
    private var closed = false

    public init() {}

    func put(_ frame: Data, from: Int, to: Int) {
        if closed { return }
        if let cont = popWaiter(from: from, to: to) {
            cont.resume(returning: frame)
        } else {
            queues[from, default: [:]][to, default: []].append(frame)
        }
    }

    func take(from: Int, to: Int) async throws -> Data {
        if var byTo = queues[from], var arr = byTo[to], !arr.isEmpty {
            let frame = arr.removeFirst()
            byTo[to] = arr; queues[from] = byTo
            return frame
        }
        if closed { throw PipelineTransportError.closed }
        return try await withCheckedThrowingContinuation { cont in
            waiters[from, default: [:]][to, default: []].append(cont)
        }
    }

    func close() {
        closed = true
        for (_, byTo) in waiters {
            for (_, conts) in byTo {
                for c in conts { c.resume(throwing: PipelineTransportError.closed) }
            }
        }
        waiters.removeAll()
    }

    private func popWaiter(from: Int, to: Int) -> CheckedContinuation<Data, Error>? {
        guard var byTo = waiters[from], var conts = byTo[to], !conts.isEmpty else { return nil }
        let c = conts.removeFirst()
        byTo[to] = conts; waiters[from] = byTo
        return c
    }
}

/// One rank's view onto a shared mailbox.
public struct LoopbackPipelineTransport: PipelineTransport {
    let mailbox: LoopbackMailbox
    let selfRank: Int

    public init(mailbox: LoopbackMailbox, selfRank: Int) {
        self.mailbox = mailbox
        self.selfRank = selfRank
    }

    public func send(_ sealedFrame: Data, to peerRank: Int) async throws {
        await mailbox.put(sealedFrame, from: selfRank, to: peerRank)
    }

    public func recv(from peerRank: Int) async throws -> Data {
        try await mailbox.take(from: peerRank, to: selfRank)
    }
}

/// In-process `TokenChannel`: the tail publishes a token per step, all ranks
/// read it. Backed by a shared actor so a multi-rank loopback run stays in
/// lockstep. On hardware this is MLX `all_gather` of the sampled token id.
public actor LoopbackTokenBus {
    private var tokens: [Int: Int] = [:]   // step -> token
    private var waiters: [Int: [CheckedContinuation<Int, Never>]] = [:]

    public init() {}

    func publish(_ token: Int, step: Int) {
        tokens[step] = token
        if let conts = waiters[step] {
            for c in conts { c.resume(returning: token) }
            waiters[step] = nil
        }
    }

    func receive(step: Int) async -> Int {
        if let t = tokens[step] { return t }
        return await withCheckedContinuation { cont in
            waiters[step, default: []].append(cont)
        }
    }
}

public struct LoopbackTokenChannel: TokenChannel {
    let bus: LoopbackTokenBus
    public init(bus: LoopbackTokenBus) { self.bus = bus }
    public func publish(token: Int, step: Int) async throws { await bus.publish(token, step: step) }
    public func receive(step: Int) async throws -> Int { await bus.receive(step: step) }
}

/// In-process `ClusterRuntime` for one rank, sharing a mailbox + token bus with
/// the other ranks in the same process. Lets `DistributedInferenceEngine` run
/// fully on one machine (tests / a single-box smoke run). The session keys come
/// from a completed handshake; sealing/opening channels are minted per request.
public struct LoopbackClusterRuntime: ClusterRuntime {
    let plan: ClusterPlan
    let mailbox: LoopbackMailbox
    let tokenBus: LoopbackTokenBus
    /// Session for sealing toward `nextRank` (nil on the tail).
    let sendSession: ClusterSession?
    /// Session for opening from `prevRank` (nil on the head).
    let recvSession: ClusterSession?

    public init(
        plan: ClusterPlan,
        mailbox: LoopbackMailbox,
        tokenBus: LoopbackTokenBus,
        sendSession: ClusterSession?,
        recvSession: ClusterSession?
    ) {
        self.plan = plan
        self.mailbox = mailbox
        self.tokenBus = tokenBus
        self.sendSession = sendSession
        self.recvSession = recvSession
    }

    public func makeStage(requestId: String) -> PipelineStage {
        PipelineStage(
            config: PipelineStageConfig(
                rank: plan.rank, worldSize: plan.worldSize,
                interval: LayerInterval(nodeId: plan.nodeId, start: 0, end: 0),
                prevRank: plan.prevRank, nextRank: plan.nextRank),
            transport: LoopbackPipelineTransport(mailbox: mailbox, selfRank: plan.rank),
            sealing: sendSession.map { ClusterSealingChannel(key: $0.sendKey()) },
            opening: recvSession.map { ClusterOpeningChannel(key: $0.recvKey()) })
    }

    public func makeTokenChannel(requestId: String) -> any TokenChannel {
        LoopbackTokenChannel(bus: tokenBus)
    }
}
