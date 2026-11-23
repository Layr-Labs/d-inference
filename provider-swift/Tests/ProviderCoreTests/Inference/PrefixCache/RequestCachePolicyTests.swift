import Foundation
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("The sealed cache_policy of a request")
struct RequestCachePolicyTests {
    private func policy(_ body: String) -> RequestCachePolicy {
        InboundChatExtensions(from: Data(body.utf8)).cachePolicy
    }

    @Test("absent or \"default\" is default; memory_only and every other value is memory_only")
    func parsesTheSealedPolicy() {
        #expect(policy(#"{"model":"m","messages":[]}"#) == .default)
        #expect(policy(#"{"_darkbloom_cache":{"nonce":"n","scope":"s"}}"#) == .default)
        #expect(policy(#"{"_darkbloom_cache":{"nonce":"n","scope":"s","cache_policy":"default"}}"#) == .default)
        for value in [#""memory_only""#, #""MEMORY_ONLY""#, #""Default""#, #""disk""#, #""""#,
                      "null", "1", "true", "{}", "[]"] {
            #expect(policy(#"{"_darkbloom_cache":{"nonce":"n","scope":"s","cache_policy":"# + value + "}}")
                    == .memoryOnly, "cache_policy \(value)")
        }
        // A member present but not an object has an unreadable policy.
        #expect(policy(#"{"_darkbloom_cache":"s"}"#) == .memoryOnly)
        #expect(policy(#"{"_darkbloom_cache":null}"#) == .memoryOnly)
    }

    @Test("the policy needs no nonce or scope, and another attempt's nonce still narrows the request")
    func policyStandsWithoutTheAttemptsNonce() throws {
        let alone = InboundChatExtensions(from: Data(#"{"_darkbloom_cache":{"cache_policy":"memory_only"}}"#.utf8))
        #expect(alone.cachePolicy == .memoryOnly && alone.sealedPrefixCache == nil)

        let other = InboundChatExtensions(from: Data(
            #"{"_darkbloom_cache":{"nonce":"other","scope":"x","cache_policy":"memory_only"}}"#.utf8))
        let frame = RemotePrefixCacheContext(cacheScope: "frame-scope", cacheReceiptNonce: "n-1")
        #expect(other.cachePolicy == .memoryOnly)
        // The scope still needs this attempt's nonce.
        #expect(frame.applying(sealed: other.sealedPrefixCache) == frame)

        let inbound = try ProviderLoop.decodeInboundChatRequest(Data(#"""
            {"model":"m","messages":[{"role":"user","content":"hi"}],"seed":3,
             "_darkbloom_cache":{"nonce":"n","scope":"s","cache_policy":"memory_only"}}
            """#.utf8))
        #expect(inbound.request.messages.count == 1 && inbound.extensions.samplingOverrides?.seed == 3)
        #expect(inbound.extensions.cachePolicy == .memoryOnly && inbound.extensions.sealedPrefixCache?.scope == "s")
    }

    @Test("a plaintext policy on the frame only narrows the sealed one")
    func thePlaintextFramePolicyOnlyNarrows() throws {
        func framePolicy(_ member: String) throws -> RequestCachePolicy {
            let json = #"{"type":"inference_request","request_id":"r","cache_scope":"s""# + member + "}"
            guard case .inferenceRequest(let request) = try ProviderProtocolCodec.decodeCoordinatorMessage(
                from: Data(json.utf8)) else { throw CancellationError() }
            return request.frameCachePolicy
        }
        #expect(try framePolicy("") == .default)
        #expect(try framePolicy(#","cache_policy":"default""#) == .default)
        for value in [#""memory_only""#, #""other""#, "7", "null"] {
            #expect(try framePolicy(#","cache_policy":"# + value) == .memoryOnly, "frame cache_policy \(value)")
        }
        #expect(RequestCachePolicy.default.narrowed(by: .default) == .default)
        #expect(RequestCachePolicy.default.narrowed(by: .memoryOnly) == .memoryOnly)
        #expect(RequestCachePolicy.memoryOnly.narrowed(by: .default) == .memoryOnly)

        let marked = CoordinatorMessage.InferenceRequest(requestId: "r", frameCachePolicy: .memoryOnly)
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(marked))
        #expect(try ProviderProtocolCodec.decodeCoordinatorMessage(from: wire) == .inferenceRequest(marked))
        let plain = try ProviderProtocolCodec.encodeCoordinatorMessage(
            .inferenceRequest(.init(requestId: "r")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("cache_policy"))
    }

    @Test("a memory_only submission keeps no prefix cache; a default one is unchanged")
    func theSubmissionPolicy() {
        let marked = PrefixCacheSubmissionPolicy(cachePolicy: .memoryOnly)
        #expect(!marked.usesSSDTier && !marked.cacheEnabled(true) && !marked.cacheEnabled(false))
        let unmarked = PrefixCacheSubmissionPolicy(cachePolicy: .default)
        #expect(unmarked.usesSSDTier && unmarked.cacheEnabled(true) && !unmarked.cacheEnabled(false))
    }

    @Test("memory-only receipts are a range no ordinary receipt reaches")
    func memoryOnlyReceiptRange() {
        #expect(!MemoryOnlyReceipt.contains(nil))
        #expect(!MemoryOnlyReceipt.contains(CBv2RequestID(1)))
        #expect(!MemoryOnlyReceipt.contains(CBv2RequestID(MemoryOnlyReceipt.bit - 1)))
        #expect(MemoryOnlyReceipt.contains(CBv2RequestID(1 | MemoryOnlyReceipt.bit)))
        // A seeded engine ID carries its own tag bit and is never in the range.
        for seed: UInt64 in 0 ..< 64 {
            let seeded = EngineV2Bridge.stableSeededRawId(seed: seed, promptTokens: [1, 2, 3])
            #expect(!MemoryOnlyReceipt.contains(CBv2RequestID(seeded)))
            #expect(!MemoryOnlyReceipt.contains(CBv2RequestID(seeded | MemoryOnlyReceipt.bit)))
        }
        #expect(!MemoryOnlyReceipt.contains(CBv2RequestID(UInt64.max)))
    }

    @Test("the local API's policy comes from DARKBLOOM_LOCAL_CACHE_POLICY, failing closed")
    func localServingPolicy() {
        let key = RequestCachePolicy.localServingEnvironmentKey
        #expect(key == "DARKBLOOM_LOCAL_CACHE_POLICY")
        #expect(RequestCachePolicy.localServing(environment: [:]) == .default)
        #expect(RequestCachePolicy.localServing(environment: [key: " "]) == .default)
        #expect(RequestCachePolicy.localServing(environment: [key: "default"]) == .default)
        #expect(RequestCachePolicy.localServing(environment: [key: "memory_only"]) == .memoryOnly)
        #expect(RequestCachePolicy.localServing(environment: [key: "yes"]) == .memoryOnly)
    }

    @Test("every build advertises cache_policy_v1, in its registration and its signed attestation alike")
    func capabilityIsAdvertised() {
        #expect(ProviderRuntimeCapability.cachePolicy.rawValue == "cache_policy_v1")
        for family in [ChipFamily.m4, .m5] {
            let hardware = HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple", chipFamily: family, chipTier: .max,
                memoryGb: 64, memoryAvailableGb: 60, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546)
            #expect(ProviderRuntimeCapabilityDetector.detectPrepared(
                hardware: hardware, boundMetallibHash: nil, naxAvailable: { false }).contains(.cachePolicy))
        }
    }

    @Test("the LaunchAgent forwards the TTL mode and the local cache policy")
    func launchAgentForwardsTheSwitches() {
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_SSD_KV_TTL_MODE"))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_LOCAL_CACHE_POLICY"))
        let forwarded = LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_SSD_KV_TTL_MODE": "fixed", "DARKBLOOM_LOCAL_CACHE_POLICY": "memory_only"])
        #expect(forwarded["DARKBLOOM_SSD_KV_TTL_MODE"] == "fixed")
        #expect(forwarded["DARKBLOOM_LOCAL_CACHE_POLICY"] == "memory_only")
    }

    @Test("a pair's ranks get the fixed TTL as a switch")
    func pairRanksGetTheFixedTTL() {
        let root = URL(fileURLWithPath: "/tmp/cluster-root")
        #expect(ClusterPrefixCacheSettings(root: root).rankSwitches["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_MODE"] == nil)
        #expect(ClusterPrefixCacheSettings(root: root, fixedTTL: true)
            .rankSwitches["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_MODE"] == "fixed")
        // The rank's environment carries it from this Mac's setting; the owner's own environment does not.
        let home = URL(fileURLWithPath: "/tmp/cluster-home")
        func rank(fixed: Bool, owner: [String: String] = [:]) -> String? {
            DistributedInstalledPrefixSSD.environment(home: home, deviceDirectory: home, ownerEnvironment: owner,
                prefixCacheOff: false, settings: ClusterPrefixCacheSettings(root: root, fixedTTL: fixed))[
                    "DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_MODE"]
        }
        #expect(rank(fixed: true) == "fixed" && rank(fixed: false) == nil)
        #expect(rank(fixed: false, owner: ["DARKBLOOM_CLUSTER_PREFIX_SSD_TTL_MODE": "fixed"]) == nil)
    }

    @Test("the local metrics name the policy counters")
    func metricsNameTheCounters() {
        let text = RequestCachePolicyCounters.shared.prometheusMetrics
        for name in ["darkbloom_cache_policy_requests_total{policy=\"default\"}",
                     "darkbloom_cache_policy_requests_total{policy=\"memory_only\"}",
                     "darkbloom_memory_only_ssd_refusals_total", "darkbloom_memory_only_ssd_tier_touches_total"] {
            #expect(text.contains(name))
        }
    }
}
