// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXVLM
import Testing
@testable import ProviderCoreFoundation
@testable import ProviderCore

/// CPU-only production identity, discovery and load-plan policy of the
/// managed Super slot. The gated checkpoint case reads the real pinned
/// checkpoint (hashing every shard) when `NEMOTRON_SUPER_CHECKPOINT_DIR` is set.
struct NemotronSuperServingPolicyTests {
    private static let superID = NemotronSuperServingPolicy.modelID
    private static let hfID = "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"

    private static func info(_ id: String, _ type: String?) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
    }

    @Test func onlyTheExactRegistryIdentityIsSupported() {
        #expect(EngineV2SupportedModels.isSupported(model: Self.info(Self.superID, "nemotron_h_omni")))
        // A provider without this policy reduced the check to the type, which
        // still refuses it: they keep dropping every Super artifact.
        #expect(!EngineV2SupportedModels.isSupported(modelType: "nemotron_h_omni"))
        for id in [Self.hfID, "EigenLabs/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4",
                   Self.superID.uppercased(), Self.superID + "-r2", " " + Self.superID] {
            #expect(!EngineV2SupportedModels.isSupported(model: Self.info(id, "nemotron_h_omni")), "\(id)")
        }
        for type in [" nemotron_h_omni", "NEMOTRON_H_OMNI", "nemotron_h", nil] as [String?] {
            #expect(!EngineV2SupportedModels.isSupported(model: Self.info(Self.superID, type)), "\(type ?? "nil")")
        }
        let (supported, unsupported) = EngineV2SupportedModels.partition(
            [Self.info(Self.hfID, "nemotron_h_omni"), Self.info(Self.superID, "nemotron_h_omni")])
        #expect(supported.map(\.id) == [Self.superID] && unsupported.map(\.id) == [Self.hfID])
    }

    @Test func servingIdentityIsTheMediaPolicyIdentity() throws {
        #expect(NemotronSuperServingPolicy.modelID == ModelMediaPolicy.nemotronSuperModelID)
        let directory = try Self.syntheticSnapshot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        #expect(ModelScanner.configDeclaresVision(at: config, modelID: Self.superID))
        #expect(ProviderLoop.modelIsVLM(at: directory, modelID: Self.superID))
        for id in [Self.hfID, Self.superID.uppercased(), Self.superID + "-r2", nil] as [String?] {
            #expect(!ModelScanner.configDeclaresVision(at: config, modelID: id), "\(id ?? "nil")")
            #expect(!ProviderLoop.modelIsVLM(at: directory, modelID: id), "\(id ?? "nil")")
        }
    }

    @Test func defaultsSpeculateAtDepthThreeForEightRequests() throws {
        // Qualification keys for speculation and width are replaced by policy.
        let plan = NemotronSuperServingPolicy.loadPlan(
            base: [NemotronSuperLocalMTP.enabledKey: "0", NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "3"],
            mode: .auto, configuredConcurrency: nil, kvBytesCapacity: 100 << 30, physicalBytes: Self.machine)
        #expect(plan.speculates && plan.requests == 8 && plan.prefixBankBytes == 16 << 30)
        #expect(plan.environment[NemotronSuperLocalMTP.enabledKey] == "1")
        #expect(plan.environment[NemotronSuperLocalMTP.depthKey] == "3,2,2,2,1")
        #expect(plan.environment[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] == "8")
        #expect(plan.environment[PrefixCachePolicy.memoryEnvironmentFlag] == "1")
        // The builder resolves exactly this configuration from the plan.
        #expect(try NemotronSuperLocalMTP.Setting.resolve(environment: plan.environment)
            == .init(depth: 3, verification: .rectangularExact, adaptive: false,
                     depthByRequests: [3, 2, 2, 2, 1]))
        #expect(try NemotronSuperLocalBridgeBuilder.concurrentRequests(
            environment: plan.environment, speculates: true) == 8)
        // Every request's fixed bytes, the owner's round work once at the
        // served 262,144-token context and the prefix bank this 100 GiB grant
        // sizes on a 256 GiB machine (16 GiB). Beside the round and the bank,
        // the KV floor is above the 5,622,055,519-byte minimum grant measured
        // for depth 3 x 8 without a bank (6,695,797,343 with a 1 GiB bank).
        #expect(plan.admissionKVBytes
            == NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: true) + (16 << 30))
        let round = NemotronSuperServingPolicy.speculativeOwnerBoundBytes(requests: 8,
            environment: plan.environment)
        #expect(plan.admissionKVBytes - plan.prefixBankBytes - round > 5_622_055_519)
    }

    /// The speculating owner's round work is held once, sized by the engine's
    /// own counts for the depth table in effect: it covers the round the
    /// pinned checkpoint reserved (`mtp_round`, measured 4,935,449,637 bytes
    /// for the default table x 8 at 65,536 tokens and 2,791,734,886 for one
    /// request at 133,120), shrinks when the table drafts less at a width,
    /// and a malformed setting counts every width at the largest depth.
    @Test func ownerRoundBoundFollowsTheDepthTable() {
        typealias Policy = NemotronSuperServingPolicy
        // The measured references below are at 65,536 tokens.
        func bound(_ depth: String?, _ requests: Int, _ context: Int = 65_536) -> Int {
            var environment: [String: String] = [:]
            if let depth { environment[NemotronSuperLocalMTP.depthKey] = depth }
            return Policy.speculativeOwnerBoundBytes(requests: requests, environment: environment,
                contextTokens: context)
        }
        #expect(bound(nil, 8) == 5_033_164_800 && bound(nil, 8) == bound("3,2,2,2,1", 8))
        #expect(bound(nil, 8) > 4_935_449_637)
        #expect(bound(nil, 1, 133_120) == 2_885_681_152 && bound(nil, 1, 133_120) > 2_791_734_886)
        // Drafting less at three or more rows shrinks it; drafting more grows it.
        #expect(bound("3,2,1", 8) == 4_362_076_160 && bound("3,2,1", 8) < bound(nil, 8))
        #expect(bound("3,2", 8) == 8_120_172_544 && bound("3", 8) == 11_878_268_928)
        #expect(bound("auto", 8) == bound("3", 8) && bound("9", 8) == bound("3", 8))
        // History copies scale with the configured context; fewer requests hold less.
        #expect(bound(nil, 8, 131_072) > bound(nil, 8) && bound(nil, 2) < bound(nil, 8))
        #expect(Policy.admissionKVBytes(requests: 8, speculates: true)
            == 8 * Policy.speculativeRequestBoundBytes + bound(nil, 8, Policy.contextTokens) + (2 << 30))
        // At the served 262,144 only the history copies grow: 16 x 1,536 x 196,608 more bytes.
        #expect(bound(nil, 8, Policy.contextTokens) == 9_865_003_008
            && bound(nil, 8, Policy.contextTokens) - bound(nil, 8) == 16 * 1_536 * 196_608)
        #expect(Policy.admissionKVBytes(requests: 8, speculates: false) == 8 * (1 << 29) + (2 << 30))
        #expect(Policy.speculativeRequestBoundBytes > 533_401_365)
    }

    /// The managed slot sizes itself: alone on the measured 256 GB M3 Ultra its
    /// re-slice grant is the whole fleet KV budget (the 90% cap less the
    /// checkpoint and the 5.5 GiB activation reserve the runner's ledger
    /// recorded), which holds both default admissions uncapped, including the
    /// 25,926,570,879-byte minimum grant measured for depth 3 x 8.
    @Test func soleSlotGrantOnTheMeasuredMacHoldsEveryDefaultAdmission() {
        let budget = UnifiedMemoryCap.kvBudgetBytes(physicalBytes: 256 << 30,
            residentWeightBytes: 75_010_188_240, activationReserveBytes: 5_905_580_032, capFraction: 0.9)
        let grant = EngineV2KVSizing.resliceGrants(existing: [],
            newcomer: .init(modelId: Self.superID, fp16KVBytesPerToken: 8_192,
                            maxContextLength: NemotronSuperServingPolicy.contextTokens),
            fleetKVBudgetBytes: budget)[Self.superID] ?? 0
        #expect(grant == Int(budget) && grant > 150 << 30)
        for mode in [MTPMode.auto, .off] {
            let plan = NemotronSuperServingPolicy.loadPlan(base: [:], mode: mode, configuredConcurrency: nil,
                kvBytesCapacity: grant)
            #expect(plan.requests == 8 && plan.speculates == (mode == .auto), "\(mode)")
            #expect(plan.admissionKVBytes == NemotronSuperServingPolicy.admissionKVBytes(
                requests: 8, speculates: plan.speculates) + plan.prefixBankBytes, "\(mode)")
        }
        #expect(grant > 25_926_570_879)
    }

    /// The depth key takes one depth, `auto` or a width table; malformed or
    /// out-of-range tables fail the load.
    @Test func depthTablesResolveOrRefuse() throws {
        func resolve(_ depth: String, _ verification: String? = nil) throws -> NemotronSuperLocalMTP.Setting? {
            var environment = [NemotronSuperLocalMTP.enabledKey: "1", NemotronSuperLocalMTP.depthKey: depth]
            environment[NemotronSuperLocalMTP.verificationKey] = verification
            return try NemotronSuperLocalMTP.Setting.resolve(environment: environment)
        }
        #expect(try resolve(" 3, 2 ,1") == .init(depth: 3, depthByRequests: [3, 2, 1]))
        #expect(try resolve("1,2") == .init(depth: 2, depthByRequests: [1, 2]))
        for bad in ["3,0", "3,,1", "4,1", "3,x", "1,1,1,1,1,1,1,1,1"] {
            #expect(throws: NemotronSuperLocalMTP.Failure.invalidDepth) { try resolve(bad) }
        }
        #expect(throws: NemotronSuperLocalMTP.Failure.invalidDepth) { try resolve("2,1", "serial") }
    }

    @Test func slotPolicyBoundsConcurrencyAndOperatorKeysStay() throws {
        let narrow = NemotronSuperServingPolicy.loadPlan(
            base: [NemotronSuperLocalMTP.depthKey: "1", NemotronSuperLocalMTP.verificationKey: "rectangular"],
            mode: .on, configuredConcurrency: 2, kvBytesCapacity: 100 << 30, physicalBytes: Self.machine)
        #expect(narrow.requests == 2 && narrow.environment[NemotronSuperLocalMTP.depthKey] == "1")
        // The operator's depth-1 table sizes the round, not the default.
        #expect(narrow.admissionKVBytes
            == NemotronSuperServingPolicy.admissionKVBytes(requests: 2, speculates: true,
                environment: narrow.environment) + (16 << 30))
        #expect(narrow.admissionKVBytes
            < NemotronSuperServingPolicy.admissionKVBytes(requests: 2, speculates: true) + (16 << 30))
        let wide = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .auto,
            configuredConcurrency: 16, kvBytesCapacity: 100 << 30)
        #expect(wide.requests == 8, "one captured verify window bounds speculation")
        let plain = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .off,
            configuredConcurrency: 16, kvBytesCapacity: 100 << 30)
        #expect(plain.requests == 16 && !plain.speculates)
        // A grant below the policy bound caps the claim at the grant itself
        // and leaves no room for the bank.
        let small = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .auto,
            configuredConcurrency: nil, kvBytesCapacity: 4 << 30)
        #expect(small.admissionKVBytes == 4 << 30 && small.prefixBankBytes == 0)
    }

    @Test func plainOwnerReusesExactTextPrefixesWhenTheGrantHoldsTheBank() {
        let plan = NemotronSuperServingPolicy.loadPlan(base: [NemotronSuperLocalMTP.enabledKey: "1"],
            mode: .off, configuredConcurrency: nil, kvBytesCapacity: 100 << 30, physicalBytes: Self.machine)
        #expect(!plan.speculates && plan.requests == 8)
        #expect(plan.environment[NemotronSuperLocalMTP.enabledKey] == nil)
        #expect(plan.environment[PrefixCachePolicy.memoryEnvironmentFlag] == "1")
        #expect(plan.prefixBankBytes == 16 << 30)
        // Every request's fixed bytes, 2 GiB and the bank; above the measured
        // 5,477,654,231-byte plain minimum for eight requests.
        #expect(plan.admissionKVBytes == 8 * (1 << 29) + (2 << 30) + (16 << 30))
        #expect(plan.admissionKVBytes - plan.prefixBankBytes > 5_477_654_231)
        let killSwitch = NemotronSuperServingPolicy.loadPlan(base: ["DARKBLOOM_CBV2_MTP": "0"],
            mode: .on, configuredConcurrency: nil, kvBytesCapacity: 100 << 30, physicalBytes: Self.machine)
        #expect(!killSwitch.speculates && killSwitch.prefixBankBytes == 16 << 30)
    }

    @Test func operatorChoiceOrASmallGrantKeepsTheBankOff() {
        for base in [[PrefixCachePolicy.memoryEnvironmentFlag: "0"], ["DARKBLOOM_PREFIX_CACHE": "0"],
                     ["DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE": "0"]] {
            for mode in [MTPMode.off, .auto] {
                let plan = NemotronSuperServingPolicy.loadPlan(base: base, mode: mode,
                    configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
                #expect(plan.prefixBankBytes == 0, "\(base) \(mode)")
            }
        }
        let tight = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .off,
            configuredConcurrency: nil, kvBytesCapacity: 6 << 30)
        #expect(tight.prefixBankBytes == 0 && tight.environment[PrefixCachePolicy.memoryEnvironmentFlag] == nil)
    }

    /// Paged KV is the managed default and holds the same default bank as
    /// contiguous storage; the operator's choice of either passes through.
    @Test func pagedStorageIsTheDefaultAndHoldsTheBank() {
        for mode in [MTPMode.off, .auto] {
            let plan = NemotronSuperServingPolicy.loadPlan(base: [:], mode: mode,
                configuredConcurrency: nil, kvBytesCapacity: 100 << 30, physicalBytes: Self.machine)
            #expect(plan.environment[NemotronSuperLocalKVBackend.key] == "paged", "\(mode)")
            #expect(plan.environment[PrefixCachePolicy.memoryEnvironmentFlag] == "1", "\(mode)")
            #expect(plan.prefixBankBytes == 16 << 30, "\(mode)")
            let contiguous = NemotronSuperServingPolicy.loadPlan(
                base: [NemotronSuperLocalKVBackend.key: "contiguous"], mode: mode,
                configuredConcurrency: nil, kvBytesCapacity: 100 << 30, physicalBytes: Self.machine)
            #expect(contiguous.environment[NemotronSuperLocalKVBackend.key] == "contiguous", "\(mode)")
            #expect(contiguous.prefixBankBytes == plan.prefixBankBytes, "\(mode)")
            #expect(contiguous.admissionKVBytes == plan.admissionKVBytes, "\(mode)")
        }
    }

    /// The default bank is at most half of what the grant leaves beside every
    /// request's fixed bytes, the prefill lane and one image's media charge,
    /// half of what the machine's cap leaves beside the rest of the single
    /// LOAD claim, a quarter of the grant and 16 GiB, in 256 MiB steps, and
    /// none below 1 GiB. It never shrinks as the grant grows.
    @Test func defaultBankFollowsTheGrantWithinItsBounds() throws {
        typealias Policy = NemotronSuperServingPolicy
        let media = Int(try #require(Policy.mediaChargeBytes(imageCount: 1)))
        let lane: Int = NemotronHModel.prefillActivationBoundBytes(tokens: 2048)
        #expect(lane == 17 << 29)
        let gib: Int = 1 << 30
        let usable = Int(UnifiedMemoryCap.hardCapBytes(physicalBytes: Self.machine))
            - Int(UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [Policy.modelID]))
        let owners: [(Int, Bool)] = [(8, true), (1, true), (8, false), (64, false)]
        for (requests, speculates) in owners {
            let admission = Policy.admissionKVBytes(requests: requests, speculates: speculates)
            let held: Int = admission + lane + media
            let claim = Int(Policy.pinnedLoadClaimBytes(speculates: speculates))
            let loadSlack: Int = usable - claim - admission - lane
            var previous = 0
            for grantGiB in 1 ... 256 {
                let grant: Int = grantGiB * gib
                let bank = Policy.defaultPrefixBankBytes(kvBytesCapacity: grant, requests: requests,
                    speculates: speculates, environment: [:], physicalBytes: Self.machine)
                let quarter: Int = grant / 4
                let doubled: Int = 2 * bank
                let slack: Int = grant - held
                let label = "\(requests) \(speculates) \(grantGiB) GiB"
                #expect(bank % Policy.prefixBankGranuleBytes == 0, "\(label)")
                #expect(bank == 0 || bank >= Policy.minimumDefaultPrefixBankBytes, "\(label)")
                #expect(bank <= Policy.maximumDefaultPrefixBankBytes && bank <= quarter, "\(label)")
                #expect(bank == 0 || (doubled <= slack && doubled <= loadSlack), "\(label)")
                #expect(bank >= previous, "\(label)")
                previous = bank
            }
        }
        // The production default (eight speculating requests at 576 MiB and
        // the owner's 9.87 GB round at the served 262,144 tokens, 15.69 GiB of
        // admission) on a 256 GiB machine: half of what the grant leaves
        // beside the admission, the 8.5 GiB lane and an image (3 GiB at
        // 34 GiB, 8.5 GiB at 45), then a quarter of the grant (15 GiB at 60),
        // the 16 GiB cap from 64 GiB.
        let sizes = [34, 45, 60, 100, 155].map { (grantGiB: Int) -> Int in
            let grant: Int = grantGiB * gib
            return Policy.defaultPrefixBankBytes(kvBytesCapacity: grant, requests: 8, speculates: true,
                environment: [:], physicalBytes: Self.machine)
        }
        let expected: [Int] = [12 << 28, 34 << 28, 15 << 30, 16 << 30, 16 << 30]
        #expect(sizes == expected, "\(sizes)")
    }

    /// A larger prefill chunk charges a larger lane; a chunk key the builder
    /// would refuse gives no default bank. An operator size wins, and only
    /// the pinned checkpoint takes the measured default.
    @Test func defaultBankFollowsTheChunkAndYieldsToTheOperator() throws {
        typealias Policy = NemotronSuperServingPolicy
        let gib: Int = 1 << 30
        // Below the cap: half of what the grant leaves beside the admission,
        // the lane and an image, with the 8.5 GiB lane and with the larger
        // 4,096-token lane.
        let grant: Int = 50 * gib
        let chunk = NemotronSuperLocalPrefill.chunkKey
        let narrowChunk = Policy.defaultPrefixBankBytes(kvBytesCapacity: grant, requests: 8, speculates: true,
            environment: [:], physicalBytes: Self.machine)
        let wide = Policy.defaultPrefixBankBytes(kvBytesCapacity: grant, requests: 8, speculates: true,
            environment: [chunk: "4096"], physicalBytes: Self.machine)
        #expect(narrowChunk == 22 << 29 && wide == 29 << 28, "\(narrowChunk) \(wide)")
        for invalid in ["0", "-1", "abc", "262145"] {
            #expect(Policy.defaultPrefixBankBytes(kvBytesCapacity: grant, requests: 8, speculates: true,
                environment: [chunk: invalid], physicalBytes: Self.machine) == 0, "\(invalid)")
        }
        let memory = [PrefixCachePolicy.memoryEnvironmentFlag: "1"]
        let large: Int = 100 * gib
        let pinned = try #require(NemotronSuperLocalPrefixCache.config(environment: memory,
            kvBytesCapacity: large, requests: 8, speculates: true, physicalBytes: Self.machine))
        #expect(pinned.maximumBytes == 16 << 30 && pinned.maximumEntries == 64)
        let generic = try #require(NemotronSuperLocalPrefixCache.config(environment: memory,
            kvBytesCapacity: large, requests: 8, speculates: true, pinned: false, physicalBytes: Self.machine))
        #expect(generic.maximumBytes == 1 << 30 && generic.maximumEntries == 32)
        let sized = memory.merging(["DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": "2147483648"]) { $1 }
        let operatorBank = try #require(NemotronSuperLocalPrefixCache.config(environment: sized,
            kvBytesCapacity: large, requests: 8, speculates: true, physicalBytes: Self.machine))
        #expect(operatorBank.maximumBytes == 2 << 30 && operatorBank.maximumEntries == 32)
        let plan = NemotronSuperServingPolicy.loadPlan(base: sized, mode: .auto,
            configuredConcurrency: nil, kvBytesCapacity: large, physicalBytes: Self.machine)
        let floor = Policy.admissionKVBytes(requests: 8, speculates: true)
        #expect(plan.prefixBankBytes == 2 << 30 && plan.admissionKVBytes == floor + (2 << 30))
        // Too small for a default bank, so the plan leaves the switch unset;
        // an operator who sets it still gets no bank from the default.
        let tight: Int = floor + gib
        let off = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .auto,
            configuredConcurrency: nil, kvBytesCapacity: tight, physicalBytes: Self.machine)
        #expect(off.prefixBankBytes == 0 && off.environment[PrefixCachePolicy.memoryEnvironmentFlag] == nil)
        #expect(off.admissionKVBytes == floor)
        #expect(NemotronSuperLocalPrefixCache.config(environment: memory, kvBytesCapacity: tight,
            requests: 8, speculates: true, physicalBytes: Self.machine) == nil)
    }

    /// The plan and the builder size one bank: the builder resolves the same
    /// requests and keys from the plan's environment.
    @Test func planAndBuilderSizeTheSameBank() throws {
        let gib: Int = 1 << 30
        let cases: [(MTPMode, Int)] = [(.auto, 60), (.auto, 100), (.auto, 155), (.off, 30), (.off, 100)]
        for (mode, grantGiB) in cases {
            let grant: Int = grantGiB * gib
            let plan = NemotronSuperServingPolicy.loadPlan(base: [:], mode: mode,
                configuredConcurrency: nil, kvBytesCapacity: grant, physicalBytes: Self.machine)
            let requests = try NemotronSuperLocalBridgeBuilder.concurrentRequests(
                environment: plan.environment, speculates: plan.speculates)
            let built = NemotronSuperLocalPrefixCache.config(environment: plan.environment,
                kvBytesCapacity: grant, requests: requests, speculates: plan.speculates,
                physicalBytes: Self.machine)
            #expect(plan.prefixBankBytes > 0 && built?.maximumBytes == plan.prefixBankBytes, "\(mode) \(grantGiB)")
            let floor = NemotronSuperServingPolicy.admissionKVBytes(requests: requests, speculates: plan.speculates)
            let claim: Int = floor + plan.prefixBankBytes
            #expect(plan.admissionKVBytes == claim && claim < grant, "\(mode) \(grantGiB)")
        }
    }

    /// The plan sizes the bank from the builder's own inputs: the installed
    /// checkpoint's pinned-ness and the loader's machine memory. Pinned and
    /// generic (fixture) owners agree on a 64 and a 256 GiB machine; a plan
    /// that sized a generic owner's bank as the pinned one's would not.
    @Test(arguments: [64, 256] as [UInt64])
    func plannedBankIsTheBuiltBankForPinnedAndGenericOwners(physicalGiB: UInt64) throws {
        typealias Policy = NemotronSuperServingPolicy
        let physical = physicalGiB << 30
        let gib: Int = 1 << 30
        for pinned in [true, false] {
            for mode in [MTPMode.auto, .off] {
                for grantGiB in [8, 40, 48, 60, 100, 155] {
                    let grant: Int = grantGiB * gib
                    let plan = Policy.loadPlan(base: [:], mode: mode, configuredConcurrency: nil,
                        kvBytesCapacity: grant, pinned: pinned, physicalBytes: physical)
                    let requests = try NemotronSuperLocalBridgeBuilder.concurrentRequests(
                        environment: plan.environment, speculates: plan.speculates)
                    let built = NemotronSuperLocalPrefixCache.config(environment: plan.environment,
                        kvBytesCapacity: grant, requests: requests, speculates: plan.speculates,
                        pinned: pinned, physicalBytes: physical)?.maximumBytes ?? 0
                    let label = "\(physicalGiB) GiB pinned=\(pinned) \(mode) grant \(grantGiB) GiB"
                    #expect(built == plan.prefixBankBytes, "\(label)")
                    #expect(plan.admissionKVBytes == min(grant,
                        Policy.admissionKVBytes(requests: requests, speculates: plan.speculates) + built), "\(label)")
                }
            }
        }
        let pinned = Policy.loadPlan(base: [:], mode: .auto, configuredConcurrency: nil,
            kvBytesCapacity: 100 * gib, pinned: true, physicalBytes: physical)
        let generic = Policy.loadPlan(base: [:], mode: .auto, configuredConcurrency: nil,
            kvBytesCapacity: 100 * gib, pinned: false, physicalBytes: physical)
        #expect(generic.prefixBankBytes == 1 << 30)
        #expect(pinned.prefixBankBytes == (physicalGiB == 256 ? 16 << 30 : 0), "\(physicalGiB) GiB")
    }

    /// The measured machine (256 GiB of unified memory).
    static let machine: UInt64 = 256 << 30

    /// A lone Super slot's grant is the fleet KV budget: the cap less the
    /// shard bytes, the activation reserve and the operator's 4 GiB reserve.
    /// On 192, 256 and 512 GiB both owners get the 16 GiB default bank, and
    /// the single LOAD claim of the speculating owner (installation, head,
    /// lane, eight requests' fixed bytes and the bank) fits under the cap with
    /// room left for other memory: 20 GB on 192 GiB.
    @Test(arguments: [192, 256, 512])
    func defaultBankOnTheSupportedMachines(physicalGiB: Int) throws {
        typealias Policy = NemotronSuperServingPolicy
        let physical = UInt64(physicalGiB) << 30
        let activation = UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [Policy.modelID])
        let budget = UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physical,
            residentWeightBytes: 75_010_188_240, activationReserveBytes: activation,
            configReserveBytes: 4 << 30)
        let grant = Int(budget)
        let auto = Policy.loadPlan(base: [:], mode: .auto, configuredConcurrency: nil,
            kvBytesCapacity: grant, physicalBytes: physical)
        let off = Policy.loadPlan(base: [:], mode: .off, configuredConcurrency: nil,
            kvBytesCapacity: grant, physicalBytes: physical)
        #expect(auto.speculates && auto.requests == 8)
        #expect(auto.prefixBankBytes == 16 << 30 && off.prefixBankBytes == 16 << 30)
        let floor = Policy.admissionKVBytes(requests: 8, speculates: true)
        let admission: Int = floor + auto.prefixBankBytes
        #expect(auto.admissionKVBytes == admission && admission < grant)
        let shares = try NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(environment: auto.environment,
            kvBytesCapacity: grant, speculates: true, physicalBytes: physical)
        #expect(shares.lane == NemotronSuperLocalPrefill.pinnedLaneBytes(
            chunkTokens: NemotronSuperLocalPrefill.defaultChunkTokens) && shares.bank == auto.prefixBankBytes)
        #expect(shares.round == Policy.speculativeOwnerBoundBytes(requests: 8, environment: auto.environment))
        // The transient runs in the serving room (lane and admission, with
        // the round and the bank inside the admission once).
        let installation = Int(Policy.pinnedLoadClaimBytes(speculates: true,
            servingBytes: shares.lane + admission))
        let claim: Int = installation + shares.lane + admission
        let room: Int = Int(UnifiedMemoryCap.hardCapBytes(physicalBytes: physical)) - Int(activation) - claim
        #expect(room > 19_000_000_000, "\(physicalGiB) GiB leaves \(room) bytes")
    }

    /// On a 128 GiB Mac the default speculating owner's LOAD claim holds its
    /// round work as one share inside the admission, not beside it, at 65,536
    /// tokens and at the served (largest accepted) 262,144: the claim is
    /// the payloads, the load transient beyond the serving room, and the
    /// serving room (lane, round, bank and KV floor) once. With the activation
    /// floor beside it the claim fits under the cap, and so does the load gate
    /// (the scan-time footprint at that context, the floor and the minimum KV).
    @Test(arguments: [65_536, NemotronSuperServingPolicy.contextTokens])
    func roundIsOneShareOfTheClaimOnA128GiBMac(context: Int) throws {
        typealias Policy = NemotronSuperServingPolicy
        let physical: UInt64 = 128 << 30
        let activation = UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [Policy.modelID])
        let grant = Int(UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physical,
            residentWeightBytes: 75_010_188_240, activationReserveBytes: activation,
            configReserveBytes: 4 << 30))
        let plan = Policy.loadPlan(base: [:], mode: .auto, configuredConcurrency: nil,
            kvBytesCapacity: grant, physicalBytes: physical)
        #expect(plan.speculates && plan.requests == 8)
        let shares = try NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(environment: plan.environment,
            kvBytesCapacity: grant, speculates: true, contextTokens: context, physicalBytes: physical)
        let round = Policy.speculativeOwnerBoundBytes(requests: 8, environment: plan.environment,
            contextTokens: context)
        #expect(shares.round == round && round > 1 << 30)
        #expect(shares.bank == plan.prefixBankBytes)
        let admission = Policy.admissionKVBytes(requests: 8, speculates: true, environment: plan.environment,
            contextTokens: context) + shares.bank
        // The KV floor the load claims beside its shares: the admission less
        // the round and the bank it already contains.
        let kvFloor = admission - shares.bank - shares.round
        let serving = try #require(shares.total) + kvFloor
        #expect(serving == shares.lane + admission, "the round and the bank are counted once")
        let install = Int(Policy.pinnedLoadClaimBytes(speculates: true, servingBytes: serving))
        #expect(install == Int(Policy.pinnedInstallationPayloadBytes + Policy.pinnedHeadPayloadBytes))
        let claim = install + serving
        let cap = Int(UnifiedMemoryCap.hardCapBytes(physicalBytes: physical))
        #expect(claim + Int(activation) <= cap, "\(context): claim \(claim) + floor \(activation) > cap \(cap)")
        // The load gate at this context: payloads, the larger of the transient
        // and the serving room with one image, the floor and the minimum KV.
        let media = try #require(Policy.mediaChargeBytes(imageCount: 1))
        let footprint = Int(Policy.pinnedLoadClaimBytes(speculates: true,
            servingBytes: shares.lane + admission - shares.bank + Int(media)))
            + shares.lane + admission - shares.bank + Int(media)
        let gate = footprint + Int(UnifiedMemoryCap.loadHeadroomBytes(modelIDs: [Policy.modelID]))
        #expect(gate <= cap, "\(context): gate \(gate) > cap \(cap)")
        let gib = { (bytes: Int) in String(format: "%.2f", Double(bytes) / 1_073_741_824) }
        print("SUPER_128_GATE context=\(context) grant=\(gib(grant)) admission=\(gib(admission)) "
            + "round=\(gib(round)) bank=\(gib(shares.bank)) lane=\(gib(shares.lane)) claim=\(gib(claim)) "
            + "activation=\(gib(Int(activation))) footprint=\(gib(footprint)) gate=\(gib(gate)) cap=\(gib(cap))")
    }

    @Test func discoveryFootprintCoversTheLargestDefaultLoadAndOneImage() throws {
        // The ship-check claim at a 28 GiB grant: installation, head and grant.
        #expect(NemotronSuperServingPolicy.pinnedInstallationLoadBytes
            + NemotronSuperServingPolicy.pinnedHeadLoadBytes + (28 << 30) == 121_013_708_416)
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 75_010_188_240)
        // Media is a serving reservation, not LOAD transient. The LOAD claim
        // holds both payloads and the larger of the two sequential transients
        // (the installation's 8,887,435,264-byte staging, not the head's
        // 7,078,617,184-byte construction), which runs in the serving room
        // (lane, admission KV, one image) before anything is served.
        #expect(NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: true) == 83_870_320_160)
        #expect(footprint.nativeLoadTransientBytes == 8_860_131_920)
        let media = try #require(NemotronSuperServingPolicy.mediaChargeBytes(imageCount: 1))
        let lane = UInt64(NemotronSuperLocalPrefill.pinnedLaneBytes(chunkTokens: 2048))
        let admission = UInt64(NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: true))
        let serving = lane + admission + media
        #expect(serving > 8_887_435_264)
        let expected = Double(73_213_230_600 + 1_769_654_296 + serving) / 1_073_741_824
        #expect(abs(footprint.estimatedMemoryGb - expected) < 1e-9)
        // 93.142 GiB at 65,536 tokens; the served 262,144 adds exactly 4.5 GiB of history copies.
        #expect(abs(footprint.estimatedMemoryGb - 97.642_094_161_361_46) < 1e-9, "\(footprint.estimatedMemoryGb)")
        let plain = NemotronSuperServingPolicy.loadPlan(base: [:], mode: .off,
            configuredConcurrency: nil, kvBytesCapacity: 100 << 30)
        // The plain owner's scan-time equivalent (no head, no bank) is smaller.
        let plainServing = lane + UInt64(NemotronSuperServingPolicy.admissionKVBytes(requests: plain.requests,
            speculates: false)) + media
        let plainBytes = NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: false,
            servingBytes: Int(plainServing)) + plainServing
        #expect(Double(plainBytes) / 1_073_741_824 < footprint.estimatedMemoryGb)
    }

    /// Super's requests, prefill lane and media charges carry its decode,
    /// prefill and tower activations; its measured floor is the uncharged
    /// residue plus slack, and a serving set with an unmeasured model keeps
    /// the default (mirrored by the platform's servability table). The floor
    /// relies on the request charges holding the decode rows, recurrent
    /// generations and verify/draft workspace: re-measure it whenever those
    /// per-request charges are trimmed toward their measured use.
    @Test func activationFloorCoversOnlyWhatTheChargesDoNot() {
        let gib: UInt64 = 1 << 30
        let id = NemotronSuperServingPolicy.modelID
        #expect(id == "nvidia-nemotron-3.5-super")
        #expect(UnifiedMemoryCap.activationFloorBytes(forModelIDs: [id]) == 2 * gib)
        #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(env: [:], modelIDs: [id]) == 2 * gib)
        #expect(UnifiedMemoryCap.activationFloorBytes(forModelIDs: [id, "gemma-4-26b"])
            == UnifiedMemoryCap.defaultActivationReserveBytes)
        // The operator's raise-only override still wins above the floor.
        #expect(UnifiedMemoryCap.resolvedActivationReserveBytes(
            env: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "4"], modelIDs: [id]) == 4 * gib)
    }

    @Test func loadClaimHoldsThePayloadsAndTheLargerSequentialTransient() throws {
        typealias Claim = NemotronSuperLoadClaim
        // Plain: the installation alone, sequential or not.
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 0, construction: 0,
            sequential: true) == 130)
        // A head: both payloads and the larger transient; summed only when the
        // staging buffers cannot be returned before the head's construction.
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 5, construction: 20,
            sequential: true) == 135)
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 5, construction: 40,
            sequential: true) == 145)
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 5, construction: 20,
            sequential: false) == 155)
        // The transient runs in the serving room claimed beside it: only what
        // exceeds that room is added; never when the transients are summed.
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 5, construction: 20,
            sequential: true, servingBytes: 12) == 123)
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 5, construction: 20,
            sequential: true, servingBytes: 64) == 105)
        #expect(try Claim.bytes(installationPayload: 100, staging: 30, headPayload: 5, construction: 20,
            sequential: false, servingBytes: 64) == 155)
        #expect(throws: Claim.Failure.invalidQuote) {
            try Claim.bytes(installationPayload: .max, staging: 1, headPayload: 0, construction: 0,
                sequential: true)
        }
        #expect(throws: Claim.Failure.invalidQuote) {
            try Claim.bytes(installationPayload: 1, staging: -1, headPayload: 0, construction: 0,
                sequential: true)
        }
        // The pinned checkpoint: the plain claim is unchanged; speculation adds
        // the head's payload, not its construction (below the staging).
        #expect(NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: false) == 82_100_665_864)
        #expect(NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: true)
            == 82_100_665_864 + 1_769_654_296)
    }

    private static let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 75_010_188_240)
    private static let model = ModelInfo(id: superID, modelType: "nemotron_h_omni", sizeBytes: 75_010_188_240,
        estimatedMemoryGb: footprint.estimatedMemoryGb, isVision: true, templateRenderOK: true,
        nativeLoadTransientBytes: footprint.nativeLoadTransientBytes)

    private static func quote(_ model: ModelInfo = Self.model, freeForLoadGb: Double = 0,
                              loadUsableGb: Double? = nil, loadHeadroomGb: Double? = 6.5,
                              resident: Bool = false, vision: Bool = false,
                              images: Int = 0) -> ProviderMessage.CapacityQuote {
        let slot = BackendSlotCapacity(model: model.id, state: "idle", numRunning: 0, numWaiting: 0,
            activeTokens: 0, maxTokensPotential: 0, maxConcurrency: 8, activeTokenBudgetUsed: 0,
            activeTokenBudgetMax: 1 << 20, queuedTokenBudget: 0)
        return CapacityQuoteEngine.quote(.init(
            probe: .init(quoteId: "q", model: model.id, promptTokensBucket: 512, maxOutputTokens: 512,
                requiresVision: vision, visionImageCount: images, deadlineRemainingMs: 9000),
            capacity: BackendCapacity(slots: resident ? [slot] : [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0,
                gpuMemoryCacheGb: 0, totalMemoryGb: 256, freeForLoadGb: freeForLoadGb,
                loadUsableGb: loadUsableGb, loadHeadroomGb: loadHeadroomGb, capacitySeq: 3),
            model: model, ttft: nil,
            visionLimits: .init(maxBufferBytes: 38 << 30, attentionElementBytes: 2, headFactor: 1),
            refusingNewWork: false))
    }

    private static func gib(_ bytes: UInt64?) -> Double { Double(bytes ?? .max) / 1_073_741_824 }

    /// Cold quotes compare the published load room with the discovery
    /// footprint (LOAD claim, prefill lane, admission KV and one image).
    @Test func coldQuotesUseTheManagedLoadFootprint() {
        let footprintGb = Self.footprint.estimatedMemoryGb
        #expect(Self.quote(freeForLoadGb: footprintGb).admissibleNow)
        #expect(Self.quote(freeForLoadGb: footprintGb, vision: true, images: 1).admissibleNow)
        // The shard bytes alone would fit; the full managed LOAD does not.
        let shardsOnly = Self.quote(freeForLoadGb: 75_010_188_240 * 1.2 / 1_073_741_824)
        #expect(!shardsOnly.admissibleNow && shardsOnly.rejectionReason == .memoryCap)
        for (vision, images) in [(false, 0), (true, 0), (true, 1), (false, 3)] {
            #expect(Self.quote(freeForLoadGb: footprintGb - 0.01, vision: vision, images: images)
                .rejectionReason == .memoryCap)
        }
        // Further images need their charge beyond the footprint's single image.
        let single = NemotronSuperServingPolicy.mediaChargeBytes(imageCount: 1)
        for images in [2, 4, 16] {
            let extraGb = Self.gib(NemotronSuperServingPolicy.mediaChargeBytes(imageCount: images)) - Self.gib(single)
            #expect(extraGb > 0)
            #expect(Self.quote(freeForLoadGb: footprintGb + extraGb, vision: true, images: images).admissibleNow)
            #expect(Self.quote(freeForLoadGb: footprintGb + extraGb - 0.01, vision: true, images: images)
                .rejectionReason == .memoryCap)
        }
        // A probe without an image count is charged the binding's maximum.
        let maximumGb = Self.gib(NemotronSuperServingPolicy.mediaChargeBytes(imageCount: 16)) - Self.gib(single)
        #expect(Self.quote(freeForLoadGb: footprintGb + maximumGb - 0.01, vision: true).rejectionReason == .memoryCap)
        #expect(Self.quote(freeForLoadGb: footprintGb + maximumGb, vision: true).admissibleNow)
    }

    /// A resident slot charges a vision probe against the published room no
    /// resident model is credited as reclaimable, net of load headroom.
    @Test func residentVisionProbesNeedTheirMediaCharge() {
        let headroom = 6.5
        for images in [1, 5, 16] {
            let chargeGb = Self.gib(NemotronSuperServingPolicy.mediaChargeBytes(imageCount: images))
            #expect(Self.quote(loadUsableGb: headroom + chargeGb, resident: true, vision: true, images: images)
                .admissibleNow)
            // Room to load elsewhere does not substitute for live room here.
            let short = Self.quote(freeForLoadGb: 200, loadUsableGb: headroom + chargeGb - 0.01,
                                   resident: true, vision: true, images: images)
            #expect(!short.admissibleNow && short.rejectionReason == .memoryCap)
        }
        #expect(Self.quote(freeForLoadGb: 200, loadUsableGb: nil, resident: true, vision: true, images: 1)
            .rejectionReason == .memoryCap)
        #expect(Self.quote(loadUsableGb: 200, loadHeadroomGb: nil, resident: true, vision: true, images: 1)
            .rejectionReason == .memoryCap)
        // Text probes on the resident slot do not consult media room.
        #expect(Self.quote(loadUsableGb: 0, resident: true).admissibleNow)
        #expect(Self.quote(loadUsableGb: nil, loadHeadroomGb: nil, resident: true).admissibleNow)
    }

    @Test func visionProbesOutsideTheImageBindingAreCapabilityRejects() {
        #expect(Self.quote(freeForLoadGb: 1_000, loadUsableGb: 1_000, vision: true, images: 17)
            .rejectionReason == .capability)
        #expect(Self.quote(loadUsableGb: 1_000, resident: true, images: 17).rejectionReason == .capability)
        // An unpinned or text-only Super entry never advertises media.
        var textOnly = Self.model
        textOnly.isVision = nil
        #expect(Self.quote(textOnly, freeForLoadGb: 200, vision: true).rejectionReason == .capability)
        // Other vision models keep the generic quote: no Super media charge.
        let other = ModelInfo(id: "org/vision", modelType: "qwen3_vl", sizeBytes: 1, estimatedMemoryGb: 8,
                              isVision: true, templateRenderOK: true)
        #expect(Self.quote(other, freeForLoadGb: 8, vision: true, images: 16).admissibleNow)
        #expect(Self.quote(other, loadUsableGb: 0, resident: true, vision: true, images: 17).admissibleNow)
    }

    @Test func scannerWithholdsTheRegistryIDWithoutThePinnedMetadata() throws {
        let directory = try Self.syntheticSnapshot()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.superID) == nil)
        let other = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.hfID))
        #expect(other.modelType == "nemotron_h_omni" && other.isVision == nil)
        #expect(other.nativeLoadTransientBytes == nil && !EngineV2SupportedModels.isSupported(model: other))
    }

    @Test func pinnedTemplatePassesTheScanRenderCheckWithMedia() throws {
        let directory = try Self.syntheticSnapshot()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The registry id renders the image and video part fixtures too.
        #expect(TemplateRenderCheck.configDeclaresVision(at: directory, modelID: Self.superID))
        #expect(TemplateRenderCheck.renderOK(at: directory, modelID: Self.superID) == true)
        #expect(TemplateRenderCheck.renderOK(at: directory, modelID: Self.hfID) == true)
    }

    /// Forced `tool_choice` is advertised for the registry id only: the owner
    /// prompt-forces and validates the call. Other ids of the type are not.
    @Test func forcedToolChoiceIsAdvertisedForTheRegistryIDOnly() {
        func info(_ id: String, _ type: String) -> ModelInfo {
            ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
        }
        #expect(ToolChoiceEnforcementPolicy.advertisesCapability(for: info(Self.superID, "nemotron_h_omni")))
        #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for: info(Self.hfID, "nemotron_h_omni")))
        #expect(!ToolChoiceEnforcementPolicy.advertisesCapability(for: info(Self.superID, "qwen3")))
    }

    /// The scanner's Super branch with the pinned `config.json` and index and
    /// a stand-in shard. Gated on the directory holding those reference files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEMOTRON_SUPER_REFERENCE_DIR"] != nil))
    func pinnedMetadataIsDiscoveredAsAnImageModel() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEMOTRON_SUPER_REFERENCE_DIR"])
        let reference = URL(fileURLWithPath: path, isDirectory: true)
        let directory = try Self.syntheticSnapshot()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["config.json", "model.safetensors.index.json"] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            try FileManager.default.copyItem(at: reference.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        #expect(NemotronSuperServingPolicy.hasPinnedMetadata(snapshotDir: directory))
        let info = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.superID))
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: info.sizeBytes)
        #expect(info.modelType == "nemotron_h_omni" && info.quantization == "nvfp4")
        #expect(info.isVision == true && info.templateRenderOK == true && info.nativeMediaTools == nil)
        #expect(info.estimatedMemoryGb == footprint.estimatedMemoryGb)
        #expect(EngineV2SupportedModels.isSupported(model: info))
        // Any other id of the same bytes keeps the ordinary text-only scan.
        let other = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.hfID))
        #expect(other.isVision == nil && !EngineV2SupportedModels.isSupported(model: other))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil))
    func pinnedCheckpointIsDiscoveredWithItsRecordedLoadCharges() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let info = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.superID))
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: info.sizeBytes)
        #expect(info.modelType == "nemotron_h_omni" && info.quantization == "nvfp4")
        #expect(info.sizeBytes == 75_010_188_240 && info.isVision == true && info.templateRenderOK == true)
        #expect(info.estimatedMemoryGb == footprint.estimatedMemoryGb)
        #expect(info.nativeLoadTransientBytes == footprint.nativeLoadTransientBytes)
        #expect(EngineV2SupportedModels.isSupported(model: info))
        // The recorded constants equal the SDK quotes over the verified shards.
        let opened = try await NemotronSuperCheckpoint.open(directory: directory)
        let installation = try NemotronSuperInstallation.loadQuote(source: opened.source,
            backendAllowanceBytes: NemotronSuperServingPolicy.backendAllowanceBytes)
        #expect(installation.payloadBytes == Int(NemotronSuperServingPolicy.pinnedInstallationPayloadBytes))
        #expect(installation.stagingBytes == Int(NemotronSuperServingPolicy.pinnedInstallationStagingBytes))
        #expect(try NemotronSuperInstallation.requiredLoadBytes(source: opened.source,
            backendAllowanceBytes: NemotronSuperServingPolicy.backendAllowanceBytes)
            == Int(NemotronSuperServingPolicy.pinnedInstallationLoadBytes))
        let staging = try NemotronSuperLocalLoad.Staging.pinned(configData: opened.inputs.configData,
            source: opened.source)
        let head = try #require(staging.head)
        let headQuote = try head.quote()
        #expect(headQuote.payloadBytes == Int(NemotronSuperServingPolicy.pinnedHeadPayloadBytes))
        #expect(headQuote.constructionBytes == Int(NemotronSuperServingPolicy.pinnedHeadConstructionBytes))
        #expect(try NemotronSuperLocalMTP.loadSupplementBytes(headQuote)
            == Int(NemotronSuperServingPolicy.pinnedHeadLoadBytes))
        #expect(try NemotronSuperLoadClaim.bytes(installation: installation, head: headQuote, sequential: true)
            == Int(NemotronSuperServingPolicy.pinnedLoadClaimBytes(speculates: true)))
        #expect(opened.inputs.fp16KVBytesPerToken == 8192 && opened.inputs.eosTokenIDs == [2, 11])
    }

    /// A `nemotron_h_omni` snapshot with the pinned template but unpinned
    /// config and index bytes.
    private static func syntheticSnapshot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("super-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let config = #"{"model_type":"nemotron_h_omni","vision_config":{"model_type":"radio"}}"#
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"weight_map":{"x":"model-00001-of-00001.safetensors"}}"#.utf8)
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        try Data(count: 16).write(to: directory.appendingPathComponent("model-00001-of-00001.safetensors"))
        try Data(#"{"bos_token":"<s>","eos_token":"<|im_end|>"}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        try template.write(to: directory.appendingPathComponent("chat_template.jinja"))
        return directory
    }
}
