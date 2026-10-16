import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// Named checks. A failed check is recorded and the run continues, so one
/// run reports every check that fails.
final class PlacementChecks {
    private(set) var passed: [String] = []
    private(set) var failures: [String] = []

    func require(_ name: String, _ value: @autoclosure () throws -> Bool) {
        do {
            if try value() { passed.append(name) } else { failures.append("Check failed: " + name) }
        } catch { failures.append("Check failed: \(name): \(error)") }
    }

    func refuses(_ name: String, because reason: String, _ body: () throws -> Void) {
        do { try body() } catch {
            if String(describing: error).contains(reason) { passed.append(name) }
            else { failures.append("Check refused for another reason: \(name): \(error)") }
            return
        }
        failures.append("Check accepted: " + name)
    }
}

let gib = 1_073_741_824

/// A constructed Mac, described only by quantities a real one reports. Its
/// memory record is produced by the host memory gate's own policy from a
/// constructed observation, exactly as a real profile's is; nothing below
/// computes admissible memory itself.
struct SyntheticMac {
    static let page = 16_384
    var physicalGiB: Double
    /// Pages free right now.
    var freeGiB: Double
    /// File cache on the inactive queue (droppable) and on the active queue.
    var inactiveCacheGiB: Double
    var activeCacheGiB: Double = 0
    /// Wired plus compressor: neither pageable nor droppable.
    var wiredGiB: Double = 4
    var compressorGiB: Double = 0
    var pressure = 1
    var swapGiB: Double = 0

    static func pages(_ gibibytes: Double) -> Int { Int((gibibytes * Double(gib) / Double(page)).rounded()) }

    /// Everything pageable that is neither free nor file cache is other
    /// programs' anonymous memory.
    var observation: QwenDenseStageLoadOSObservation {
        let physical = Self.pages(physicalGiB), wired = Self.pages(wiredGiB), compressor = Self.pages(compressorGiB)
        let free = Self.pages(freeGiB), inactiveFile = Self.pages(inactiveCacheGiB), activeFile = Self.pages(activeCacheGiB)
        let pageable = physical - wired - compressor
        let anonymous = max(0, pageable - free - inactiveFile - activeFile)
        // Half of the anonymous memory sits on each queue.
        let inactiveAnonymous = anonymous / 2
        let active = activeFile + anonymous - inactiveAnonymous, inactive = inactiveFile + inactiveAnonymous
        return .init(startedNanoseconds: 900, completedNanoseconds: 1_000, timestampUTC: "2026-10-09T00:00:00Z",
            physicalMemoryBytes: physical * Self.page, pageSizeBytes: Self.page, kernelFreePages: free, freePages: free,
            inactivePages: inactive, speculativePages: 0, actualFreeBytes: free * Self.page,
            estimatedReclaimableBytes: (free + inactive) * Self.page, pressureLevel: pressure,
            swapUsedBytes: Int(swapGiB * Double(gib)), activePages: active, fileBackedPages: inactiveFile + activeFile,
            anonymousPages: anonymous, wiredPages: wired, purgeablePages: 0, compressorPages: compressor,
            kernelFileCacheMinimumPages: nil, inactiveFileBackedPages: inactiveFile,
            inactiveAnonymousPages: inactiveAnonymous, compressionPages: 0, swapoutPages: 0, liveCompressionPages: 0)
    }

    static let now: UInt64 = 1_100

    /// The profile such a Mac would report. The GPU's working set and the
    /// allocator limit are inputs a real Mac reports; here they follow the
    /// proportions MLX itself uses for its default limit (the allocator allows
    /// one and a half times the working set, at most 95 % of memory) with the
    /// working set at three quarters of memory. They are test inputs, not a
    /// claim about any machine.
    func profile(chip: String = "Synthetic") throws -> ClusterDeviceProfile {
        let physical = Self.pages(physicalGiB) * Self.page
        let workingSet = physical / 4 * 3
        return try .init(chip: chip, performanceCores: 8, efficiencyCores: 4, gpuCores: nil, osVersion: "27.0",
            osBuild: "SYNTH", physicalMemoryBytes: physical, gpuRecommendedWorkingSetBytes: workingSet,
            gpuMaximumBufferBytes: physical / 2, allocatorLimitBytes: min(workingSet / 2 * 3, physical / 100 * 95),
            memory: .gate(observation, now: Self.now),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
    }

    /// An idle Mac of this size: everything pageable is free except a little cache.
    static func idle(_ physicalGiB: Double) -> SyntheticMac {
        let wired = max(2.5, physicalGiB * 0.03), other = max(3, physicalGiB * 0.04)
        return .init(physicalGiB: physicalGiB, freeGiB: physicalGiB - wired - other - 1, inactiveCacheGiB: 1, wiredGiB: wired)
    }

    func device(_ label: String, speed: ClusterDeviceSpeed = .assumedEqual, chip: String = "Synthetic") throws -> ClusterPlacementDevice {
        .init(label: label, profile: try profile(chip: chip), speed: speed)
    }
}

/// A made-up family: uniform layers, a cut after every layer.
struct SyntheticFamily: ClusterPlacementFamily {
    var runtimeModelID = "synthetic"
    var layerCount: Int
    var admittedCuts: [Int]
    var structural: [Int]?
    var structuralCuts: [Int] { structural ?? Array(1..<layerCount) }
    var generationModes: [ClusterGenerationMode] = [.pipeline, .pipelineCompactDecode, .phaseSplit]
    var prefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]
    var maximumPromptTokens = 8192, maximumOutputTokens = 128, maximumChunkTokens = 512
    var boundaryBytesPerToken = 8192
    var stateBytesPerToken = 512
    /// Set to make the family answer as if a layer's tensors were scattered.
    var scatter = false
    /// Set to make the embedding one both ends load, and odd layers cost double.
    var tiedEmbedding = false
    var unevenCost = false
    func loadsAtBothEnds(storedTensor name: String) -> Bool { tiedEmbedding && name.hasPrefix("embed.") }
    func layerCost(_ layer: Int) -> Double { unevenCost && layer % 2 == 1 ? 2 : 1 }

    func layer(ofStoredTensor name: String) -> Int? {
        let parts = name.split(separator: ".")
        guard parts.count >= 2, parts[0] == "layers" else { return nil }
        return Int(parts[1])
    }
    func stage(ofStoredTensor name: String, cut: Int) throws -> Int? {
        if name.hasPrefix("vision.") { return nil }
        if name.hasPrefix("embed.") { return 0 }
        if name.hasPrefix("head.") { return 1 }
        guard let layer = layer(ofStoredTensor: name) else { throw ClusterPlacementError("Unknown tensor \(name)") }
        if scatter, layer == 3 { return cut % 2 }
        return layer < cut ? 0 : 1
    }
    func layerKind(_ layer: Int) -> String { "block" }
    func requestState(layer: Int) throws -> ClusterPlacementLayerState { .init(fixedBytes: 0, bytesPerToken: stateBytesPerToken) }

    /// Tensors of a model with these bytes per layer, each layer in pieces no
    /// larger than `largestTensor`.
    static func tensors(layerBytes: [Int], embed: Int, head: Int, excluded: Int = 0, largestTensor: Int) -> [ClusterPlacementStoredTensor] {
        var result: [ClusterPlacementStoredTensor] = []
        func split(_ prefix: String, _ bytes: Int) {
            var left = bytes, index = 0
            while left > 0 {
                let piece = min(left, largestTensor)
                result.append(.init(name: "\(prefix).t\(index)", byteCount: piece)); left -= piece; index += 1
            }
        }
        split("embed", embed); split("head", head)
        if excluded > 0 { split("vision", excluded) }
        for (index, bytes) in layerBytes.enumerated() { split("layers.\(index)", bytes) }
        return result
    }
}

func syntheticLayout(layers: Int, layerGiB: Double, embedGiB: Double = 0.5, headGiB: Double = 0.5,
                     admitted: [Int]? = nil, modes: [ClusterGenerationMode]? = nil,
                     largestGiB: Double = 0.5) throws -> ClusterModelLayout {
    var family = SyntheticFamily(layerCount: layers, admittedCuts: admitted ?? Array(1..<layers))
    if let modes { family.generationModes = modes }
    let per = Int(layerGiB * Double(gib))
    return try ClusterModelLayoutBuilder.build(family: family,
        tensors: SyntheticFamily.tensors(layerBytes: Array(repeating: per, count: layers), embed: Int(embedGiB * Double(gib)),
            head: Int(headGiB * Double(gib)), largestTensor: Int(largestGiB * Double(gib))),
        artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64))
}

/// The 173 GB mixture-of-experts model, from the per-cut byte table of the
/// family survey: 48 layers, a dense first layer, 47 expert layers of 3.2825
/// GiB, a cut legal after every layer, six cuts in its resident row, no phase
/// split, tensors of at most 1 GiB, about 0.2 GiB of state at the largest
/// request. The survey's rows are checked against this layout in the checks.
func surveyedMiMoLayout() throws -> ClusterModelLayout {
    let expert = Int(3.2825 * Double(gib))
    var family = SyntheticFamily(runtimeModelID: "surveyed_mimo_v26_flash", layerCount: 48, admittedCuts: [24, 26, 28, 30, 32, 34])
    family.generationModes = [.pipeline, .pipelineCompactDecode]
    family.stateBytesPerToken = 538
    // Embedding plus the dense first layer are 0.89 GiB together; the head 0.61 GiB.
    return try ClusterModelLayoutBuilder.build(family: family,
        tensors: SyntheticFamily.tensors(layerBytes: [Int(0.29 * Double(gib))] + Array(repeating: expert, count: 47),
            embed: Int(0.60 * Double(gib)), head: Int(0.61 * Double(gib)), excluded: Int(3.46 * Double(gib)), largestTensor: gib),
        artifactSHA256: String(repeating: "c", count: 64), configurationSHA256: String(repeating: "d", count: 64))
}

func measured(prefill: Double, decode: Double, sustainedPrefill: Double? = nil, sustainedDecode: Double? = nil,
              note: String = "constructed for a check") -> ClusterDeviceSpeed {
    .init(source: .measured, absolute: true, rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode),
        sustained: sustainedPrefill.map { .init(prefillTokensPerSecond: $0, decodeTokensPerSecond: sustainedDecode ?? decode) },
        explanation: note)
}

/// Retained registered metadata (names, shapes, dtypes and byte counts only).
struct RetainedQwenInputs: Decodable {
    struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
    struct Profile: Decodable {
        let configuration: Data
        let canonicalTensors: [Tensor]
        var stored: [ClusterPlacementStoredTensor] {
            canonicalTensors.map { .init(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape) }
        }
    }
    let nine: Profile
    let twentySeven: Profile
}
