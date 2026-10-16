// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLLM
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
    static let modelType = "nemotron_h_omni"
    /// SHA-256 of the pinned `config.json` (NVIDIA revision `7d4bc747`).
    static let configSHA256 = "35189a8038d1b1f934e58cba50eb7e97b42a4da569424e35b9fd1048058bc7ea"
    static var indexSHA256: String { NemotronSuperCheckpointPin.index }

    /// Context window served; the bridge builder admits at most this.
    static let contextTokens = 16_384
    /// Explicit backend/allocator allowance added to the installation's LOAD
    /// quote. Unmeasured; the full-checkpoint load peaked 1.6 GB below the
    /// quote that includes it.
    static let backendAllowanceBytes = 2 << 30
    /// Measured full-checkpoint default (M3 Ultra, 256 GB): depth-3 exact
    /// rectangular speculation serving up to eight requests.
    static let defaultDraftDepth = 3
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
        /// The plain owner's exact text prefix bank; zero when absent.
        let prefixBankBytes: Int
        /// KV headroom the LOAD claim requires, never above the grant.
        let admissionKVBytes: Int
    }

    /// Speculation and concurrency come from provider policy and replace any
    /// value of those keys; the depth defaults to `defaultDraftDepth`.
    /// Verification, prefill chunk and decode-step keys keep the operator's
    /// value or the builder default. The plain owner turns exact text prefix
    /// reuse on (`DARKBLOOM_PREFIX_CACHE_MEMORY`) when the grant holds every
    /// request's fixed bytes beside the bank; an operator value, including
    /// the global kill switch, wins. The speculating owner has no bank.
    static func loadPlan(base: [String: String], mode: MTPMode, configuredConcurrency: Int?,
                         kvBytesCapacity: Int) -> LoadPlan {
        let speculates = Self.speculates(mode: mode, environment: base)
        let requests = concurrentRequests(configured: configuredConcurrency, speculates: speculates)
        var environment = base
        environment[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] = String(requests)
        if speculates {
            environment[NemotronSuperLocalMTP.enabledKey] = "1"
            if environment[NemotronSuperLocalMTP.depthKey] == nil {
                environment[NemotronSuperLocalMTP.depthKey] = String(defaultDraftDepth)
            }
        } else {
            environment.removeValue(forKey: NemotronSuperLocalMTP.enabledKey)
            let flag = PrefixCachePolicy.memoryEnvironmentFlag
            var candidate = environment
            candidate[flag] = "1"
            if environment[flag] == nil,
                let bank = NemotronSuperLocalPrefixCache.config(environment: candidate,
                    kvBytesCapacity: kvBytesCapacity, speculates: false, modelID: modelID)?.maximumBytes,
                kvBytesCapacity >= admissionKVBytes(requests: requests, speculates: false) + bank {
                environment = candidate
            }
        }
        let bank = NemotronSuperLocalPrefixCache.config(environment: environment,
            kvBytesCapacity: kvBytesCapacity, speculates: speculates, modelID: modelID)?.maximumBytes ?? 0
        return LoadPlan(environment: environment, speculates: speculates, requests: requests,
            prefixBankBytes: bank,
            admissionKVBytes: min(kvBytesCapacity,
                admissionKVBytes(requests: requests, speculates: speculates) + bank))
    }

    /// Fixed bytes one request reserves (recurrent state, request workspace,
    /// any speculation charge), measured on the pinned checkpoint at 16,384
    /// context and 2,048-token chunks and rounded up: 2,944,562,564 at depth 3,
    /// 516,253,712 plain.
    static let speculativeRequestBoundBytes = 3 << 30
    static let plainRequestBoundBytes = 1 << 29

    /// KV headroom the LOAD claim requires: every configured request's fixed
    /// bytes plus 2 GiB for KV and the admission watermark. The built bridge's
    /// exact grant check (`UnserviceableGrant`) stays authoritative.
    static func admissionKVBytes(requests: Int, speculates: Bool) -> Int {
        let perRequest = speculates ? speculativeRequestBoundBytes : plainRequestBoundBytes
        return max(1, requests) * perRequest + (2 << 30)
    }

    /// LOAD charges of the pinned checkpoint, header-derived and recorded from
    /// its full load: the installation quote including `backendAllowanceBytes`,
    /// and the embedded head's payload and construction supplement. The
    /// managed load recomputes and claims both from the verified shards.
    static let pinnedInstallationLoadBytes: UInt64 = 82_100_665_864
    static let pinnedHeadLoadBytes: UInt64 = 8_848_271_480

    struct DiscoveryFootprint: Equatable {
        /// The default configuration's LOAD claim (installation and head),
        /// owner-wide prefill lane, admission KV and the media charge of one
        /// single-image request, in GiB.
        let estimatedMemoryGb: Double
        /// LOAD bytes above the shard bytes: staging, backend allowance and
        /// head construction. Not activation, KV or media.
        let nativeLoadTransientBytes: UInt64
    }

    /// Scan-time requirement of the largest default configuration (eight
    /// speculative requests; the plain owner with its prefix bank needs
    /// less), so a cold quote or pre-accept check never admits a load the
    /// managed claim then refuses, and the load leaves room for an image.
    static func discoveryFootprint(sizeBytes: UInt64) -> DiscoveryFootprint {
        let load = pinnedInstallationLoadBytes + pinnedHeadLoadBytes
        let lane = UInt64(NemotronHModel.prefillActivationBoundBytes(
            tokens: NemotronSuperLocalPrefill.defaultChunkTokens))
        let kv = UInt64(admissionKVBytes(requests: defaultConcurrentRequests, speculates: true))
        // Unreachable unless the binding refuses its own largest image; the
        // footprint then fails closed instead of advertising room it lacks.
        let media = mediaChargeBytes(imageCount: 1) ?? UInt64(Int.max)
        return DiscoveryFootprint(
            estimatedMemoryGb: Double(load + lane + kv + media) / 1_073_741_824,
            nativeLoadTransientBytes: load > sizeBytes ? load - sizeBytes : 0)
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
