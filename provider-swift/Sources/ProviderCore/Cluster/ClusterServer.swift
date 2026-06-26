/// ClusterServer -- run the proven `ClusterPipeline` as a request server.
///
/// The head node receives requests from a coordinator; the PEER nodes have no
/// coordinator, so before each generation all ranks must agree on what to run.
/// A control round over the ring (all_gather) carries the head's next-request
/// descriptor — prompt token ids + maxTokens — to every peer, so they enter the
/// SAME `generate` call in lockstep. A sentinel descriptor (maxTokens == 0)
/// tells peers to shut down.
///
/// This keeps the *exact* verified decode loop (ClusterPipeline) and adds only a
/// lockstep control channel around it — avoiding the unverified per-rank
/// collective ordering of the earlier RingClusterRuntime path.
///
/// Control-round encoding (all_gather of a fixed-width int32 vector from the
/// head; peers contribute zeros and read the head's slot):
///   [0]   = maxTokens   (0 ⇒ shutdown)
///   [1]   = promptLen
///   [2..] = prompt token ids (capped at CONTROL_MAX_PROMPT)

import Foundation
import MLX

private let CONTROL_MAX_PROMPT = 8192
private let CONTROL_WIDTH = 2 + CONTROL_MAX_PROMPT

public struct ClusterRequestDescriptor: Sendable {
    public let promptTokens: [Int]
    public let maxTokens: Int
    public init(promptTokens: [Int], maxTokens: Int) {
        self.promptTokens = promptTokens
        self.maxTokens = maxTokens
    }
    static let shutdown = ClusterRequestDescriptor(promptTokens: [], maxTokens: 0)
}

public struct ClusterServer {
    let plan: ClusterPlan
    let group: MLXDistributedGroup
    let pipeline: ClusterPipeline
    let eosTokenIds: Set<Int>

    public init(plan: ClusterPlan, group: MLXDistributedGroup, pipeline: ClusterPipeline, eosTokenIds: Set<Int>) {
        self.plan = plan
        self.group = group
        self.pipeline = pipeline
        self.eosTokenIds = eosTokenIds
    }

    private func headRankSlot(_ gathered: [Int32]) -> ArraySlice<Int32> {
        // head is rank 0; all_gather concatenates [width] per rank → rank 0's
        // vector is the first CONTROL_WIDTH entries.
        gathered.prefix(CONTROL_WIDTH)
    }

    /// Broadcast the head's next request to all ranks; returns the agreed
    /// descriptor on every rank. The head passes `next`; peers pass nil.
    public func exchangeRequest(_ next: ClusterRequestDescriptor?) throws -> ClusterRequestDescriptor {
        var vec = [Int32](repeating: 0, count: CONTROL_WIDTH)
        if plan.isHead, let next {
            let n = min(next.promptTokens.count, CONTROL_MAX_PROMPT)
            vec[0] = Int32(next.maxTokens)
            vec[1] = Int32(n)
            for i in 0..<n { vec[2 + i] = Int32(next.promptTokens[i]) }
        }
        let gathered = try group.allGather(MLXArray(vec, [CONTROL_WIDTH]))
        gathered.eval()
        let slot = Array(headRankSlot(gathered.asArray(Int32.self)))
        let maxTokens = Int(slot[0])
        let n = Int(slot[1])
        let prompt = (0..<max(0, n)).map { Int(slot[2 + $0]) }
        return ClusterRequestDescriptor(promptTokens: prompt, maxTokens: maxTokens)
    }

    /// PEER loop: stay in lockstep with the head's control rounds. The head
    /// broadcasts a descriptor every round — an IDLE descriptor (maxTokens<0)
    /// when no request is pending, a real one when serving, or the shutdown
    /// sentinel (maxTokens==0). Idle rounds keep both sides in the same
    /// `all_gather` so the ring never sits with one side parked in a collective
    /// the other hasn't joined (which times out and tears down the ring).
    public func runPeerLoop(makeChannels: () -> (ClusterSealingChannel?, ClusterOpeningChannel?)) throws {
        var reqCounter = 0
        // Dead-ring backoff. When the head is ALIVE, `exchangeRequest` blocks in
        // the all_gather barrier until the head joins — so a healthy idle cluster
        // costs nothing here (the peer parks in the collective, not in a spin).
        // When the head DIES, the collective stops blocking and starts throwing
        // immediately; without a backoff the loop would busy-spin a CPU core for
        // as long as the process lives (observed: a hung peer pegging a core for
        // hours). So on each consecutive failure we sleep with exponential
        // backoff, and after `maxConsecutiveFailures` we conclude the ring is
        // gone and exit cleanly rather than spin forever.
        let maxConsecutiveFailures = 50
        let backoffCapSeconds = 5.0
        var consecutiveFailures = 0

        while true {
            let desc: ClusterRequestDescriptor
            do {
                desc = try exchangeRequest(nil)
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutiveFailures {
                    // The ring control round has failed repeatedly — the head is
                    // almost certainly gone. Stop spinning and let the peer exit.
                    throw error
                }
                // Exponential backoff, capped: 10ms, 20ms, 40ms … up to 5s.
                let delay = min(backoffCapSeconds, 0.01 * pow(2.0, Double(min(consecutiveFailures, 9))))
                Thread.sleep(forTimeInterval: delay)
                continue
            }
            consecutiveFailures = 0               // a successful round resets backoff
            if desc.maxTokens == 0 { return }    // shutdown
            if desc.maxTokens < 0 { continue }   // idle keepalive round
            reqCounter += 1
            let (seal, open) = makeChannels()
            let pl = ClusterPipeline(
                plan: plan, group: group, shard: pipeline.shard,
                hiddenSize: pipeline.hiddenSize, sealCh: seal, openCh: open)
            _ = try pl.generate(
                promptTokens: desc.promptTokens, maxTokens: desc.maxTokens,
                requestId: "req-\(reqCounter)", eosTokenIds: eosTokenIds, onToken: { _ in })
        }
    }

    /// An IDLE descriptor — the head broadcasts this on rounds with no pending
    /// request, keeping the ring's control collective alive in lockstep.
    public static var idleDescriptor: ClusterRequestDescriptor {
        ClusterRequestDescriptor(promptTokens: [], maxTokens: -1)
    }
}
