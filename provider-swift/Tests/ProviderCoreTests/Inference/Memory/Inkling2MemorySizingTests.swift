import Foundation
import Testing

@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Inkling 2 Mini on a 48 GB Mac (the smallest M5 Max configuration): the
/// provider's own KV budget (`UnifiedMemoryCap.kvBudgetBytes`: the cap minus
/// resident weights, the activation reserve and the OS reserve) must hold at
/// least eight streams at a 32K context, each with the target's full-slot K/V,
/// its sliding plateau and convolution state, plus the DSpark drafter's own
/// cache. Arithmetic only, from the pinned configuration; the measured
/// runtime gate (calibrated admission) is a separate real-weight check.
@Suite("Inkling 2 memory sizing")
struct Inkling2MemorySizingTests {
    static let gib: UInt64 = 1 << 30
    /// `model-00001-of-00001.safetensors` and `mtp.safetensors` at 6e7c8248.
    static let targetBytes: UInt64 = 19_526_019_168
    static let drafterBytes: UInt64 = 635_801_416

    static func configuration() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(
            forResource: "config.json", withExtension: nil, subdirectory: "Fixtures/Inkling2"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The drafter's own K/V for one stream at `context` tokens (BF16): its
    /// full layers grow per token, its sliding layers stop at their window.
    static func drafterKVBytes(_ mtp: [String: Any], context: Int) throws -> Int {
        let layers = try #require(mtp["num_hidden_layers"] as? Int)
        let local = Set(try #require(mtp["local_layer_ids"] as? [Int]))
        let window = try #require(mtp["sliding_window_size"] as? Int)
        let perToken = 2 * (try #require(mtp["num_key_value_heads"] as? Int)) * (try #require(mtp["head_dim"] as? Int)) * 2
        return (0..<layers).reduce(0) { total, layer in
            total + perToken * (local.contains(layer) ? min(window, context) : context)
        }
    }

    /// The slot is sized and served for 524,288 tokens of prompt plus output,
    /// half the checkpoint's 1,048,576.
    @Test func theServedWindowIsHalfTheCheckpointContext() throws {
        let url = try #require(Bundle.module.url(
            forResource: "config.json", withExtension: nil, subdirectory: "Fixtures/Inkling2"))
        #expect(KVEstimation.parseModelArchitecture(at: url).maxContextLength == 524_288)
    }

    @Test func fortyEightGigabytesHoldEightStreamsAt32K() throws {
        let root = try Self.configuration()
        let text = try #require(root["text_config"] as? [String: Any])
        let layout = try #require(Inkling2ModelIdentity.CacheLayout(textConfiguration: text))
        let context = 32_768
        let mtp = try #require(root["mtp_config"] as? [String: Any])
        let perStream = context * layout.kvBytesPerToken(bytesPerElement: 2)
            + layout.slidingWindowBytes(bytesPerElement: 2)
            + layout.convolutionStateBytes(bytesPerElement: 2)
            + (try Self.drafterKVBytes(mtp, context: context))
        let resident = Self.targetBytes + SpecDecLimits.residentEstimate(artifactBytes: Self.drafterBytes)
        let budget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: 48 * Self.gib, residentWeightBytes: resident,
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            configReserveBytes: 4 * Self.gib, capFraction: UnifiedMemoryCap.defaultCapFraction)
        let streams = Int(budget) / perStream
        #expect(perStream == 1_073_741_824 + 167_772_160 + 1_916_928 + 142_606_336)
        #expect(streams >= 8, "budget \(budget) B holds \(streams) streams of \(perStream) B")
        // The budget the scanner-sized load leaves: on the order of 18 GiB.
        #expect(budget > 17 * Self.gib && budget < 20 * Self.gib, "\(budget)")
    }

    /// The two load gates on a 48 GB Mac, through the production budget actor
    /// fed a 48 GiB machine: the scanned estimate (every safetensors file on
    /// disk, drafter shard included, × 1.2: quantized bytes, not dequantized)
    /// plus the activation reserve and the 1 GiB minimum KV must fit under
    /// OS-available memory less the cap-implied reserve (48 − 0.9 × 48 =
    /// 4.8 GiB). The free-for-load gate and the pending-load claim agree: the
    /// load needs about 33.8 GiB available, so 34 GiB admits and 33 refuses.
    /// The inline drafter adds nothing on top: its shard is already counted.
    @Test(arguments: [(34, true), (33, false)])
    func fortyEightGigabyteLoadGates(availableGiB: Int, admits: Bool) async throws {
        let physical = 48 * Self.gib
        let available = UInt64(availableGiB) * Self.gib
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes,
            memorySnapshot: { .init(total: physical, active: 0, cache: 0, systemAvailable: available) })
        let estimateGb = Double(Self.targetBytes + Self.drafterBytes) / Double(Self.gib) * 1.2
        let requiredGb = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: estimateGb,
            headroomGb: Double(UnifiedMemoryCap.loadHeadroomBytes(
                activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)) / Double(Self.gib))
        #expect(abs(requiredGb - 29.03) < 0.01, "\(requiredGb)")
        #expect(budget.loadReserveBytes == physical - UnifiedMemoryCap.hardCapBytes(
            physicalBytes: physical, capFraction: UnifiedMemoryCap.defaultCapFraction))
        #expect((budget.availableForLoadGb() >= requiredGb) == admits,
                "free for load \(budget.availableForLoadGb()) GiB, required \(requiredGb) GiB")
        let lease = await budget.claimPendingLoad(
            requestID: "pending-load:inkling-48", weightBytes: ProviderLoop.pendingLoadReservationBytes(
                estimatedWeightsGb: estimateGb, extraWeightBytes: 0))
        #expect((lease != nil) == admits)
        if let lease { #expect(await budget.finishPendingLoad(lease)) }
    }

    /// The cap-fraction emulation of a 48 GB Mac on a 256 GiB host is not a
    /// 48 GB Mac: the load reserve becomes the cap-implied 212.8 GiB, so the
    /// load needs about 241.8 GiB available and a shared host refuses it
    /// before any weight is read. It needs a 48 GiB machine, not a fraction.
    @Test func capFractionEmulationRefusesOnASharedHost() {
        let physical = 256 * Self.gib
        let fraction = 0.1688
        let reserve = UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: physical, configReserveBytes: 0, capFraction: fraction)
        #expect(reserve > 212 * Self.gib && reserve < 213 * Self.gib, "\(reserve)")
        let free = ModelLoadAdmission.freeForLoadGb(
            totalBytes: physical, systemAvailableBytes: 115 * Self.gib,
            gpuActiveBytes: 0, gpuCacheBytes: 0, reserveBytes: reserve)
        #expect(free == 0)
    }
}
