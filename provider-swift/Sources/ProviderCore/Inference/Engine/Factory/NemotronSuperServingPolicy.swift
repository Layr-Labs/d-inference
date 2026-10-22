// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

/// Production identity and defaults of native Nemotron 3.5 Super VL NVFP4.
///
/// The provider serves exactly one Super artifact: the complete pinned NVIDIA
/// checkpoint (88 shards, the embedded MTP head in shard 88) registered as
/// `modelID`. Any other id, configuration or index of the `nemotron_h_omni`
/// architecture stays out of discovery, as it does on providers without this
/// policy. Every shard's SHA-256 is verified by the managed load itself.
enum NemotronSuperServingPolicy {
    static let modelID = ModelMediaPolicy.nemotronSuperModelID
    static let modelType = ModelMediaPolicy.nemotronSuperModelType
    /// SHA-256 of the pinned `config.json` (NVIDIA revision `7d4bc747`).
    static let configSHA256 = "35189a8038d1b1f934e58cba50eb7e97b42a4da569424e35b9fd1048058bc7ea"
    static var indexSHA256: String { NemotronSuperCheckpointPin.index }

    /// Context window the managed slot serves and advertises (prompt plus
    /// output): the whole verified ceiling. Prefill time and long-document
    /// recall at this length are routing decisions for the coordinator, not
    /// a cap here; see the managed slot in `docs/architecture/inference.md`.
    static let contextTokens = maximumContextTokens
    /// Largest context the bridge builder and the image binding accept,
    /// verified on the pinned checkpoint. The checkpoint's attention has no
    /// positional encoding (`max_position_embeddings` 1,048,576); the bound
    /// is what was measured correct and admitted on 256 GB.
    static let maximumContextTokens = 262_144
    /// Explicit backend/allocator allowance added to the installation's LOAD
    /// quote. Unmeasured; the full-checkpoint load peaked 1.6 GB below the
    /// quote that includes it.
    static let backendAllowanceBytes = 2 << 30
    /// Measured full-checkpoint default (M3 Ultra, 256 GB, natural chat, code,
    /// math and long-form prompts, greedy): exact rectangular speculation for
    /// up to eight requests, the draft depth set by the requests decoding in
    /// the step (`defaultDepthByRequests`, at most `defaultDraftDepth`).
    /// Aggregate tok/s, plain owner against the best fixed depth: 32.5 / 57.0
    /// (depth 3) alone, 50.7 / 65.0 (2) at two, 67.2 / 78.4 (2) at four and
    /// 82.8 / 86.9 (1) at eight clients.
    static let defaultDraftDepth = 3
    static let defaultDepthByRequests = [3, 2, 2, 2, 1]
    static let defaultConcurrentRequests = 8

    /// Exact registry id and canonical `model_type`; no alias or substring.
    static func isServingIdentity(modelID: String, modelType: String?) -> Bool {
        modelID == Self.modelID && modelType == Self.modelType
    }

    /// Scan-time identity: `config.json` (8.7 MB) and
    /// `model.safetensors.index.json` (19.5 MB) are the pinned bytes. Reads
    /// only those two bounded files.
    static func hasPinnedMetadata(snapshotDir: URL) -> Bool {
        sha256(of: snapshotDir.appendingPathComponent("config.json"), limit: 16 << 20) == configSHA256
            && sha256(of: snapshotDir.appendingPathComponent("model.safetensors.index.json"),
                      limit: 32 << 20) == indexSHA256
    }

    private static func sha256(of url: URL, limit: Int) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 0, size <= limit, let data = try? Data(contentsOf: url), data.count == size
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `mtp_mode` `auto` and `on` speculate with the embedded head; `off` and
    /// the `DARKBLOOM_CBV2_MTP` kill switch serve the plain owner.
    static func speculates(mode: MTPMode, environment: [String: String]) -> Bool {
        mode != .off && SpecDecArtifactFunnel.killSwitchEnabled(environment: environment)
    }

    /// Requests served at once: `defaultConcurrentRequests` unless the slot
    /// policy (`engine_v2_max_concurrent`, or its per-model entry) is
    /// explicit, which is then an upper bound. Never above one captured verify
    /// window with speculation, or the batched decode rows without.
    static func concurrentRequests(configured: Int?, speculates: Bool) -> Int {
        let limit = speculates
            ? NemotronHModel.superMTPMaximumWindowRequests : NemotronSuperRecurrentAdapter.decodeRowLimit
        return min(max(1, configured ?? defaultConcurrentRequests), limit)
    }

    /// The managed load's configuration under one KV grant.
    struct LoadPlan: Equatable {
        /// Runtime policy passed to the builder (`DARKBLOOM_NEMOTRON_SUPER_*`).
        let environment: [String: String]
        let speculates: Bool
        let requests: Int
        /// The owner's exact prefix checkpoint bank; zero when absent.
        let prefixBankBytes: Int
        /// KV headroom the LOAD claim requires, never above the grant.
        let admissionKVBytes: Int
    }

    /// Speculation and concurrency come from provider policy and replace any
    /// value of those keys; the depth defaults to `defaultDepthByRequests`
    /// and KV storage to segmented paged. Verification, prefill chunk,
    /// decode-step and KV storage keys keep the operator's value, else the
    /// default above or the builder's. Either owner, on either KV backend,
    /// turns exact prefix reuse on (`DARKBLOOM_PREFIX_CACHE_MEMORY`) when the
    /// grant has room for a `defaultPrefixBankBytes` bank (or an
    /// operator-sized one) beside every request's fixed bytes; an operator
    /// value, including the global kill switch, wins. The builder sizes the
    /// same bank from the same grant, requests and keys.
    static func loadPlan(base: [String: String], mode: MTPMode, configuredConcurrency: Int?,
                         kvBytesCapacity: Int, pinned: Bool = true,
                         physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LoadPlan {
        let speculates = Self.speculates(mode: mode, environment: base)
        let requests = concurrentRequests(configured: configuredConcurrency, speculates: speculates)
        var environment = base
        environment[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] = String(requests)
        if speculates {
            environment[NemotronSuperLocalMTP.enabledKey] = "1"
            if environment[NemotronSuperLocalMTP.depthKey] == nil {
                environment[NemotronSuperLocalMTP.depthKey] =
                    defaultDepthByRequests.map(String.init).joined(separator: ",")
            }
        } else {
            environment.removeValue(forKey: NemotronSuperLocalMTP.enabledKey)
        }
        if environment[NemotronSuperLocalKVBackend.key] == nil {
            environment[NemotronSuperLocalKVBackend.key] = "paged"
        }
        let flag = PrefixCachePolicy.memoryEnvironmentFlag
        var candidate = environment
        candidate[flag] = "1"
        if environment[flag] == nil,
            let bank = NemotronSuperLocalPrefixCache.config(environment: candidate,
                kvBytesCapacity: kvBytesCapacity, requests: requests, speculates: speculates,
                pinned: pinned, physicalBytes: physicalBytes, modelID: modelID)?.maximumBytes,
            kvBytesCapacity >= admissionKVBytes(requests: requests, speculates: speculates,
                environment: environment) + bank {
            environment = candidate
        }
        let bank = NemotronSuperLocalPrefixCache.config(environment: environment,
            kvBytesCapacity: kvBytesCapacity, requests: requests, speculates: speculates,
            pinned: pinned, physicalBytes: physicalBytes, modelID: modelID)?.maximumBytes ?? 0
        return LoadPlan(environment: environment, speculates: speculates, requests: requests,
            prefixBankBytes: bank,
            admissionKVBytes: min(kvBytesCapacity,
                admissionKVBytes(requests: requests, speculates: speculates, environment: environment) + bank))
    }

    /// Fixed bytes one request reserves (recurrent state, request workspace,
    /// the assistant's frontier and partial history block), measured on the
    /// pinned checkpoint with 2,048-token chunks and rounded up: 533,401,365
    /// at depth 3, 516,253,712 plain, at any configured context. The
    /// assistant's history is charged per token of each request (1,536 bytes
    /// beside 8,192 of KV), like the KV, not by the configured window; its
    /// round work is the owner's, once (`speculativeOwnerBoundBytes`).
    static let speculativeRequestBoundBytes = 9 << 26
    static let plainRequestBoundBytes = 1 << 29

    /// Units of the speculating owner's once-per-engine reservation
    /// (`mtp_round`), recorded from the pinned checkpoint's ready charges
    /// (default table, eight requests and one request, 65,536 and 133,120
    /// tokens): one chained draft step, the prompt-history chunk with the
    /// backend scratch allowance, the verify window's fixed workspace and its
    /// part per position (4 positions 209,996,800 bytes, 16 positions
    /// 236,007,424), one recurrent generation as projected, and one history
    /// row's FP8 codes and decoded mirror of K and V.
    static let pinnedMTPDraftStepBytes = 22_622_736
    static let pinnedMTPOwnerFixedBytes = 562_037_760 + (256 << 20)
    static let pinnedMTPWindowFixedBytes = 192 << 20
    static let pinnedMTPWindowBytesPerPosition = 2_167_552
    static let pinnedRecurrentGenerationBytes = 173_014_960
    static let pinnedMTPHistoryBytesPerToken = 1_536
    /// Allocator rounding the engine projects beyond the logical units
    /// (0.4 MB for one request, 1.1 MB for eight, measured), bounded by this
    /// slack; the total is then rounded up to the granule.
    static let mtpOwnerAllocatorSlackBytes = 64 << 20
    static let mtpOwnerGranuleBytes = 64 << 20

    /// The speculating owner's MTP work, held once whatever the number of
    /// requests, for `requests` at `contextTokens` under the depth the runtime
    /// policy selects (the environment's, else `defaultDepthByRequests`):
    /// the engine's own round counts for that table
    /// (`CBv2MTPAllocationLimits`, the counts the SDK reserves) times the
    /// pinned units plus `mtpOwnerAllocatorSlackBytes`, rounded up to
    /// `mtpOwnerGranuleBytes`. It shrinks when the table drafts less at a width. A malformed
    /// setting is counted as adaptive at the largest depth, every width's
    /// worst case. An estimate for the LOAD claim; the builder reserves the
    /// engine's exact `ownerBytes` and refuses the build when they do not fit.
    static func speculativeOwnerBoundBytes(requests: Int, environment: [String: String] = [:],
                                           contextTokens: Int = contextTokens) -> Int {
        var resolved = environment
        resolved[NemotronSuperLocalMTP.enabledKey] = "1"
        if resolved[NemotronSuperLocalMTP.depthKey] == nil {
            resolved[NemotronSuperLocalMTP.depthKey] = defaultDepthByRequests.map(String.init).joined(separator: ",")
        }
        let maximum = NemotronSuperMTPAssistant.Settings.maximumDepth
        let setting = (try? NemotronSuperLocalMTP.Setting.resolve(environment: resolved)) ?? nil
        let config = setting.map { NemotronSuperLocalMTP.config($0, requests: requests) }
            ?? NemotronSuperLocalMTP.config(.init(depth: maximum, adaptive: true), requests: requests)
        let depth = config.maxDraftTokens
        let round = CBv2MTPAllocationLimits.roundBounds(config)
        let generations = CBv2MTPAllocationLimits.capturedWindowGenerations(config, perRequest: 3)
        let copies = CBv2MTPAllocationLimits.historyCopies(config, requests: requests)
        let historyRows = max(1, contextTokens) + depth + 1
        let parts = [
            (round.steps, pinnedMTPDraftStepBytes), (1, pinnedMTPOwnerFixedBytes),
            (1, pinnedMTPWindowFixedBytes), (round.positions, pinnedMTPWindowBytesPerPosition),
            (generations, pinnedRecurrentGenerationBytes),
            (copies, pinnedMTPHistoryBytesPerToken * historyRows),
        ]
        var total = mtpOwnerAllocatorSlackBytes
        for (count, bytes) in parts {
            let (product, productOverflow) = max(0, count).multipliedReportingOverflow(by: bytes)
            let (sum, sumOverflow) = total.addingReportingOverflow(product)
            guard !productOverflow, !sumOverflow else { return Int.max }
            total = sum
        }
        let remainder = total % mtpOwnerGranuleBytes
        let (rounded, overflow) = total.addingReportingOverflow(
            remainder == 0 ? 0 : mtpOwnerGranuleBytes - remainder)
        return overflow ? Int.max : rounded
    }

    /// KV headroom the LOAD claim requires: every configured request's fixed
    /// bytes, with speculation the owner's round work once
    /// (`speculativeOwnerBoundBytes` for the environment's depth table at
    /// `contextTokens`), plus 2 GiB for KV and the admission watermark. The
    /// built bridge's exact grant check (`UnserviceableGrant`) and the
    /// builder's exact round reservation stay authoritative.
    static func admissionKVBytes(requests: Int, speculates: Bool, environment: [String: String] = [:],
                                 contextTokens: Int = contextTokens) -> Int {
        let requests = max(1, requests)
        let perRequest = speculates ? speculativeRequestBoundBytes : plainRequestBoundBytes
        let owner = speculates
            ? speculativeOwnerBoundBytes(requests: requests, environment: environment,
                contextTokens: contextTokens)
            : 0
        let (fixed, fixedOverflow) = requests.multipliedReportingOverflow(by: perRequest)
        let (withOwner, ownerOverflow) = fixed.addingReportingOverflow(owner)
        let (total, overflow) = withOwner.addingReportingOverflow(2 << 30)
        return fixedOverflow || ownerOverflow || overflow ? Int.max : total
    }

    // MARK: - Prefix checkpoint bank

    /// Largest default bank. One long-prompt entry (a first and a newest
    /// checkpoint) measured 0.39-0.44 GB at ~5.9K tokens on the full
    /// checkpoint, so this keeps a few dozen long entries.
    static let maximumDefaultPrefixBankBytes = 16 << 30
    /// Smallest default bank: about two long entries. Less is no bank.
    static let minimumDefaultPrefixBankBytes = 1 << 30
    static let prefixBankGranuleBytes = 256 << 20

    /// The default exact-prefix bank of the pinned checkpoint's owner under a
    /// KV grant, carved from that grant. Two slacks bound it:
    ///
    ///     serving = grant - admissionKVBytes(requests, speculates)
    ///                     - prefill lane bound(chunk) - one image's media charge
    ///     load    = memory cap - activation reserve - LOAD bytes (installation
    ///                     and any head) - admissionKVBytes - lane bound
    ///     bank    = min(16 GiB, grant / 4, serving / 2, load / 2),
    ///               rounded down to 256 MiB; no bank below 1 GiB
    ///
    /// Serving: the lane and media charges come from the same ledger the grant
    /// describes, so half of what remains beside them stays free for KV, more
    /// images and other owners. Load: the single LOAD claim, taken before any
    /// allocation, holds the installation, any head, the lane, the bank and the
    /// requests' KV (`NemotronSuperLocalLoad`), so half of what the machine's
    /// cap leaves beside the rest stays free for other memory and images. The
    /// grant / 4 term is the engine's own bank ceiling when a re-slice shrinks
    /// the grant. An unparseable or out-of-range chunk key gives no bank (the
    /// load then refuses the key itself).
    static func defaultPrefixBankBytes(kvBytesCapacity: Int, requests: Int, speculates: Bool,
                                       environment: [String: String],
                                       physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        guard let chunk = NemotronSuperLocalPrefill.requestedChunkTokens(environment: environment),
            kvBytesCapacity > 0, let media = mediaChargeBytes(imageCount: 1)
        else { return 0 }
        let admission = admissionKVBytes(requests: requests, speculates: speculates, environment: environment)
        let lane = NemotronSuperLocalPrefill.pinnedLaneBytes(chunkTokens: chunk)
        let serving = kvBytesCapacity - admission - lane - Int(clamping: media)
        let claim = Int(clamping: pinnedLoadClaimBytes(speculates: speculates))
        let usable = Int(clamping: UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes))
            - Int(clamping: UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: [modelID]))
        let load = usable - claim - admission - lane
        guard serving > 0, load > 0 else { return 0 }
        let bank = min(maximumDefaultPrefixBankBytes, kvBytesCapacity / 4, serving / 2, load / 2)
        let rounded = bank - bank % prefixBankGranuleBytes
        return rounded >= minimumDefaultPrefixBankBytes ? rounded : 0
    }

    /// LOAD quotes of the pinned checkpoint, header-derived and recorded from
    /// its verified shards: the installation's resident payload and staging
    /// (including `backendAllowanceBytes`), and the embedded head's payload and
    /// construction allowance. The managed load recomputes them and claims
    /// `NemotronSuperLoadClaim.bytes`: both payloads and the larger transient.
    static let pinnedInstallationPayloadBytes: UInt64 = 73_213_230_600
    static let pinnedInstallationStagingBytes: UInt64 = 8_887_435_264
    static let pinnedHeadPayloadBytes: UInt64 = 1_769_654_296
    static let pinnedHeadConstructionBytes: UInt64 = 7_078_617_184
    static var pinnedInstallationLoadBytes: UInt64 { pinnedInstallationPayloadBytes + pinnedInstallationStagingBytes }
    static var pinnedHeadLoadBytes: UInt64 { pinnedHeadPayloadBytes + pinnedHeadConstructionBytes }

    /// The managed load's LOAD bytes for the installation and, when it
    /// speculates, the head (transients sequential), beside `servingBytes`
    /// of serving room claimed with them (`NemotronSuperLoadClaim`).
    static func pinnedLoadClaimBytes(speculates: Bool, servingBytes: Int = 0) -> UInt64 {
        let bytes = try? NemotronSuperLoadClaim.bytes(
            installationPayload: Int(pinnedInstallationPayloadBytes),
            staging: Int(pinnedInstallationStagingBytes),
            headPayload: speculates ? Int(pinnedHeadPayloadBytes) : 0,
            construction: speculates ? Int(pinnedHeadConstructionBytes) : 0, sequential: true,
            servingBytes: servingBytes)
        return UInt64(bytes ?? Int.max)
    }

    struct DiscoveryFootprint: Equatable {
        /// The default configuration's resident installation and head, and
        /// the larger of their load transient and the serving room (owner-wide
        /// prefill lane, admission KV and the media charge of one single-image
        /// request), in GiB.
        let estimatedMemoryGb: Double
        /// LOAD bytes above the shard bytes: staging, backend allowance and
        /// head construction. Not activation, KV or media.
        let nativeLoadTransientBytes: UInt64
    }

    /// Scan-time requirement of the largest default configuration (eight
    /// speculative requests; the plain owner needs less), so a cold quote or
    /// pre-accept check never admits a load the managed claim then refuses,
    /// and the load leaves room for an image. The prefix bank is not part of
    /// it: `loadPlan` enables the bank only when the grant also holds it.
    static func discoveryFootprint(sizeBytes: UInt64) -> DiscoveryFootprint {
        let lane = UInt64(NemotronSuperLocalPrefill.pinnedLaneBytes(
            chunkTokens: NemotronSuperLocalPrefill.defaultChunkTokens))
        let kv = UInt64(admissionKVBytes(requests: defaultConcurrentRequests, speculates: true))
        // Unreachable unless the binding refuses its own largest image; the
        // footprint then fails closed instead of advertising room it lacks.
        let media = mediaChargeBytes(imageCount: 1) ?? UInt64(Int.max)
        let serving = lane + kv + media
        // The load transient runs in the serving room before anything serves.
        let load = pinnedLoadClaimBytes(speculates: true, servingBytes: Int(clamping: serving))
        let transient = pinnedLoadClaimBytes(speculates: true)
        return DiscoveryFootprint(
            estimatedMemoryGb: Double(load + serving) / 1_073_741_824,
            nativeLoadTransientBytes: transient > sizeBytes ? transient - sizeBytes : 0)
    }

    // MARK: - Image media charge

    /// Request limits of `NemotronSuperLocalImageBinding`: the encoded body
    /// its ingress quote admits, the images one body may carry, and the size
    /// of the only template the owner renders (`NemotronSuperPromptContract`).
    static let maximumEncodedBodyBytes = 8 << 20
    static let maximumImages = 16
    static let pinnedTemplateBytes = 12_927

    /// Decoder workspace `NemotronSuperImageDecode` quotes for its largest
    /// admitted raster (64 Mi pixels; JPEG at 16 bytes per pixel and axes to
    /// 65,500, PNG at 14 and axes to 131,072; 128 bytes per row) with its
    /// 8 MiB scratch and the SDK's 256 MiB normalization budget. Each
    /// image's two encoded copies are charged per request, below.
    static let maximumImageDecodeBytes: UInt64 =
        max(16 * (64 << 20) + 128 * 65_500, 14 * (64 << 20) + 128 * 131_072) + (8 << 20) + (256 << 20)

    /// Per visual token: both retained Float32 copies of its 32 x 32 RGB
    /// grid pixels and its 4,096-wide Float32 feature row.
    static let mediaBytesPerVisualToken: UInt64 = 32 * 32 * 3 * 4 * 2 + 4_096 * 4

    /// The largest grid preprocessing admits: 104 x 128 patches (13,312),
    /// 3,328 visual tokens.
    static var largestImageGrid: NemotronSuperImagePreprocessing.Grid? {
        try? NemotronSuperImagePreprocessing.grid(width: 2_048, height: 1_664)
    }

    /// Upper bound of what the image binding reserves from the shared ledger
    /// for one encoded request with `imageCount` images, charged until the
    /// owner retires it: the ingress quote at the largest body, each image's
    /// decoder workspace, two copies of every decoded byte the body can
    /// carry, visual tokens up to the context, and one largest-grid tower
    /// and projector activation (images are prepared one at a time). The
    /// binding refuses contexts above `contextTokens`. nil outside
    /// 1...`maximumImages`.
    static func mediaChargeBytes(imageCount: Int) -> UInt64? {
        guard (1...maximumImages).contains(imageCount), let grid = largestImageGrid,
            let ingress = try? NemotronSuperLocalImageBinding.encodedHeaderQuote(
                bodyBytes: maximumEncodedBodyBytes, templateBytes: pinnedTemplateBytes),
            let activation = try? NemotronSuperLocalImageBinding.towerActivationBytes(
                [(grid.heightPatches, grid.widthPatches)])
        else { return nil }
        let encodedCopies = UInt64(maximumEncodedBodyBytes / 4 * 3) * 2
        let tokens = UInt64(min(imageCount * grid.tokens, contextTokens))
        return ingress + UInt64(imageCount) * maximumImageDecodeBytes + encodedCopies
            + tokens * mediaBytesPerVisualToken + activation
    }
}
