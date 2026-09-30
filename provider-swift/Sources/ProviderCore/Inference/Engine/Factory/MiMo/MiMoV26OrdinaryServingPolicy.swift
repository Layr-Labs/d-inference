// Copyright © 2026 Eigen Labs.
import Darwin
import Foundation
import MLXLLM
import MLXVLM

/// Normal ProviderLoop/Standalone entrypoint, not a benchmark SPI. These are
/// refusal ceilings only; the existing transaction/ledger still prices and
/// owns the actual load, codec, decoder, native features and consumer lifetime.
enum MiMoV26OrdinaryServingPolicy {
    enum SidecarPresence: Equatable { case absent, present }
    struct IngestBounds {
        let maximumImages, maximumVideos, maximumImagePixels, maximumVideoPixels: Int
        let maximumPartBytes, maximumMetadataBytes: Int
        static var current: Self {
            .init(maximumImages: MediaIngest.maxImagesPerRequest,
                maximumVideos: MediaIngest.maxVideosPerRequest,
                maximumImagePixels: MediaIngest.maxRequestImagePixels,
                maximumVideoPixels: MediaIngest.maxRequestVideoFramePixels,
                maximumPartBytes: MediaIngest.maxMediaDecodedBytes,
                maximumMetadataBytes: localInferenceMaxUploadBytes)
        }
    }
    struct Resolved {
        let media: MiMoV26ServingLoad.DecodedMediaPolicy
        let audio: MiMoV26ServingLoad.DecodedAudioPolicy?
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (n, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw MiMoV26ServingLoadError.arithmeticOverflow }
        return n
    }
    private static func multiply(_ values: Int...) throws -> Int {
        try values.reduce(1) { a, b in
            let (n, overflow) = a.multipliedReportingOverflow(by: b)
            guard a >= 0, b >= 0, !overflow else { throw MiMoV26ServingLoadError.arithmeticOverflow }
            return n
        }
    }
    private static func ceil(_ n: Int, by divisor: Int) throws -> Int {
        guard n >= 0, divisor > 0 else { throw MiMoV26ServingLoadError.metadata }
        return n / divisor + (n % divisor == 0 ? 0 : 1)
    }
    private static func integer(_ fields: [String: MiMoV26JSONValue], _ key: String) throws -> Int {
        guard case .number(let n) = fields[key], n > 0, n <= Decimal(Int32.max) else {
            throw MiMoV26ServingLoadError.metadata
        }
        let value = NSDecimalNumber(decimal: n).intValue
        guard Decimal(value) == n else { throw MiMoV26ServingLoadError.metadata }
        return value
    }

    /// Presence chooses a STRICT inspection attempt, never codec authority.
    /// A broken symlink/file/permission failure is not an absent optional asset.
    static func sidecarPresence(root: URL) throws -> SidecarPresence {
        var value = stat()
        let url = root.appendingPathComponent("audio_tokenizer")
        if lstat(url.path, &value) == 0 {
            guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw MiMoV26ServingLoadError.metadata
            }
            return .present
        }
        guard errno == ENOENT else { throw MiMoV26ServingLoadError.metadata }
        return .absent
    }

    static func inspect(directory: URL, budget: GlobalKVCacheBudget,
        deviceLimits: VisionTowerBudget.Limits? = nil) throws -> MiMoV26ServingLoad? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let metadata = try MiMoV26ServingLoad.readMetadata(root.appendingPathComponent("config.json"), limit: 1 << 20)
        struct Declaration: Decodable { let model_type: String? }
        guard try JSONDecoder().decode(Declaration.self, from: metadata.bytes).model_type == "mimo_v2" else {
            return nil // no MiMo policy/native-device read for another family
        }
        let configuration = try JSONDecoder().decode(MiMoV26Configuration.self, from: metadata.bytes)
        if configuration.rawFields["language_model_only"] == .bool(true) {
            // Match the scanner's existing media policy. Retain the same strict
            // text load; no optional decoder or media capability is fabricated.
            let load = try MiMoV26ServingLoad.inspect(directory: root)
            guard let load, load.request.binding.configSHA256 == MiMoV26ServingLoad.hash(metadata.bytes),
                  load.plan.bundlePlan.configuration == configuration else {
                throw MiMoV26ServingLoadError.changedDescriptor
            }
            return load
        }
        let sidecar = try sidecarPresence(root: root)
        // Existing process-lifetime device/LOWER-ONLY patch ceiling, not a
        // tensor allocation/evaluation or a claim of free runtime memory.
        let resolved = try make(configuration: configuration, sidecar: sidecar,
            physicalBytes: budget.physicalMemoryBytes, reserveBytes: budget.loadReserveBytes,
            deviceLimits: deviceLimits ?? VisionTowerBudget.liveLimits, ingest: .current)
        let load = try MiMoV26ServingLoad.inspect(directory: root,
            decodedMediaPolicy: resolved.audio == nil ? resolved.media : nil,
            decodedAudioPolicy: resolved.audio)
        guard let load, load.request.binding.configSHA256 == MiMoV26ServingLoad.hash(metadata.bytes),
              load.plan.bundlePlan.configuration == configuration,
              try sidecarPresence(root: root) == sidecar else {
            throw MiMoV26ServingLoadError.changedDescriptor
        }
        // A present sidecar was parsed by the authentic held-FD source/session;
        // its whole selected digest is still verified by real load, not here.
        guard (sidecar == .present) == (load.audioLoadRequest != nil) else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        return load
    }

    /// Scalar policy construction. Injected values support metadata-only tests;
    /// this creates no load permit, reservation, model or SidecarLoaded owner.
    static func make(configuration c: MiMoV26Configuration, sidecar: SidecarPresence,
        physicalBytes: UInt64, reserveBytes: UInt64, deviceLimits: VisionTowerBudget.Limits,
        ingest: IngestBounds) throws -> Resolved {
        guard let vision = c.vision, let audioPatch = c.audio,
              reserveBytes > 0, physicalBytes > reserveBytes,
              let workingBytes = Int(exactly: physicalBytes - reserveBytes),
              deviceLimits.maxBufferBytes > 0,
              [ingest.maximumImages, ingest.maximumVideos, ingest.maximumImagePixels,
               ingest.maximumVideoPixels, ingest.maximumPartBytes, ingest.maximumMetadataBytes].allSatisfy({ $0 > 0 })
        else { throw MiMoV26ServingLoadError.metadata }
        let sampling = try MiMoV26EncodedVisualDecoder.Sampling(configuration: c)
        let maximumMedia = try add(ingest.maximumImages, ingest.maximumVideos)
        let floatBytes = MemoryLayout<Float>.stride
        let workingElements = workingBytes / floatBytes
        let singleBufferElements = min(workingBytes, deviceLimits.maxBufferBytes) / floatBytes
        guard workingElements > 0, singleBufferElements > 0, sampling.maximumFrames > 0 else {
            throw MiMoV26ServingLoadError.metadata
        }
        let contextPatches = try multiply(c.maxPositionEmbeddings, vision.spatialMergeSize, vision.spatialMergeSize)
        let maximumPatches = min(contextPatches, Int(Int32.max), deviceLimits.operatorMaxPatches ?? Int.max)
        let patchComponents = try multiply(3, vision.temporalPatchSize, vision.patchSize, vision.patchSize)
        let outputElements = min(singleBufferElements, try multiply(maximumPatches, patchComponents))
        let inputElements = min(workingElements,
            try multiply(3, add(ingest.maximumImagePixels, ingest.maximumVideoPixels)))
        guard maximumPatches > 0, inputElements > 0, outputElements > 0 else {
            throw MiMoV26ServingLoadError.metadata
        }

        let audioLimits: MiMoV26AudioInputLimits
        let audioPatchLimits: MiMoV26AudioPatchLimits
        if sidecar == .present {
            guard let fields = c.processorFields else { throw MiMoV26ServingLoadError.metadata }
            let rate = try integer(fields, "audio_sampling_rate")
            let fft = try integer(fields, "audio_nfft")
            let hop = try integer(fields, "audio_hop_length")
            let segment = try integer(fields, "audio_segment_size")
            let stride = try integer(fields, "audio_stride_size")
            let pool = try integer(fields, "audio_avg_pooler")
            guard rate == 24000, segment == audioPatch.segmentSize else {
                throw MiMoV26ServingLoadError.metadata
            }
            // Ordinary encoded transport currently accepts mono24k PCM16/F32
            // WAV; the minimum stored sample width is two bytes. Actual decode
            // and the selected codec independently validate format/geometry.
            let samples = min(Int(Int32.max), workingElements,
                try multiply(ingest.maximumPartBytes / 2, maximumMedia))
            let melFrames = try add(samples / hop, maximumMedia)
            let segments = try add(ceil(melFrames, by: segment), maximumMedia)
            let paddedMel = try multiply(segments, segment)
            let reduction = try multiply(stride, pool)
            let codeFrames = try add(ceil(melFrames, by: reduction), maximumMedia)
            guard samples > 0, fft <= Int(Int32.max), reduction > 0 else {
                throw MiMoV26ServingLoadError.metadata
            }
            audioLimits = .init(maximumClips: maximumMedia, maximumChannels: 1, maximumSampleRate: rate,
                maximumInputSamples: samples, maximumResampledSamples: samples,
                maximumResampleCoefficients: singleBufferElements,
                maximumMelFrames: melFrames, maximumSegments: segments,
                maximumPaddedMelFrames: paddedMel, maximumWorkingElements: workingElements,
                frontendFrameBlockSize: segment, rvqTileFrames: max(1, segment / reduction))
            audioPatchLimits = .init(maximumClips: maximumMedia, maximumFrames: codeFrames,
                maximumPatches: c.maxPositionEmbeddings, maximumWorkingElements: workingElements)
        } else {
            // Inert positive bounds satisfy the common visual planner schema.
            // No audio/AV request can reach these without a real audio policy.
            audioLimits = .init(maximumClips: 1, maximumChannels: 1, maximumSampleRate: 24000,
                maximumInputSamples: 1, maximumResampledSamples: 1, maximumResampleCoefficients: 1,
                maximumMelFrames: 1, maximumSegments: 1, maximumPaddedMelFrames: 1,
                maximumWorkingElements: 1, frontendFrameBlockSize: 1, rvqTileFrames: 1)
            audioPatchLimits = .init(maximumClips: 1, maximumFrames: 1,
                maximumPatches: 1, maximumWorkingElements: 1)
        }
        let limits = MiMoV26MultimodalLimits(maximumMedia: maximumMedia,
            maximumVideoFrames: sampling.maximumFrames, maximumPromptTokens: c.maxPositionEmbeddings,
            maximumMetadataBytes: ingest.maximumMetadataBytes,
            maximumMetadataNodes: min(1_000_000, ingest.maximumMetadataBytes), maximumMetadataDepth: 128,
            pixels: .init(maximumInputElements: inputElements, maximumOutputElements: outputElements,
                maximumWorkingBytes: workingBytes),
            vision: .init(maximumPatches: maximumPatches, maximumAttentionScoreElements: singleBufferElements),
            audio: audioLimits, audioPatch: audioPatchLimits)
        let media = try MiMoV26ServingLoad.DecodedMediaPolicy(limits: limits,
            maximumReservationBytes: UInt64(workingBytes), additionalSystemReserveBytes: reserveBytes)
        let audio = sidecar == .present
            ? try MiMoV26ServingLoad.DecodedAudioPolicy(media: media,
                maximumSidecarReservationBytes: UInt64(workingBytes), additionalSystemReserveBytes: reserveBytes) : nil
        return .init(media: media, audio: audio)
    }
}
