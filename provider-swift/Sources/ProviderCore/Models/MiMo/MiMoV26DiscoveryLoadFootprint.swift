import Foundation
import MLXVLM

/// Discovery quotation of the SAME full native load requests used by ordinary
/// MiMo serving. Reads metadata/headers/stat only: no payload authentication,
/// MLX arrays, device query, model construction, load permit or reservation.
/// Malformed/unknown inventory keeps the scanner's conservative legacy price.
enum MiMoV26DiscoveryLoadFootprint {
    struct Estimate: Equatable, Sendable {
        let storedBytes: UInt64
        let mainLoadBytes: UInt64
        let sidecarLoadBytes: UInt64
        let totalBytes: UInt64
        /// Supplement above ALL scanner-counted stored payload bytes. This is
        /// a LOAD allowance, not measured residency or physical-byte coverage.
        let transientBytes: UInt64
    }

    private enum Refusal: Error { case inventory, overflow }

    static func estimate(snapshotDir: URL, modelType: String?, sizeBytes: UInt64) -> Estimate? {
        guard modelType == "mimo_v2", sizeBytes > 0 else { return nil }
        return try? inspect(snapshotDir: snapshotDir, sizeBytes: sizeBytes)
    }

    /// Revalidate a declared MiMo full-LOAD quote after hashing/setup awaits.
    /// Unlike Qwen's quote, MiMo has no SSD-excluded payload. Legacy nil keeps
    /// its existing behavior only in the dedicated native caller: that caller
    /// admits/claims the fresh main+sidecar requests and rechecks their held
    /// descriptors/permits independently of these scanner fields.
    static func isCurrent(_ info: ModelInfo, directory: URL) -> Bool {
        guard info.modelType == "mimo_v2", (info.ssdOffloadedWeightBytes ?? 0) == 0,
              info.sizeBytes > 0, info.estimatedMemoryGb.isFinite, info.estimatedMemoryGb > 0
        else { return false }
        guard let declared = info.nativeLoadTransientBytes else { return true }
        guard let current = estimate(snapshotDir: directory, modelType: info.modelType,
                                     sizeBytes: info.sizeBytes),
              declared >= current.transientBytes,
              info.estimatedMemoryGb >= Double(current.totalBytes) / 1_073_741_824
        else { return false }
        return true
    }

    private static func inspect(snapshotDir: URL, sizeBytes: UInt64) throws -> Estimate {
        try Task.checkCancellation()
        let root = snapshotDir.resolvingSymlinksInPath().standardizedFileURL
        guard let main = try MiMoV26ServingLoad.inspect(directory: root) else {
            throw Refusal.inventory
        }
        let configuration = main.plan.bundlePlan.configuration
        let languageOnly = configuration.rawFields["language_model_only"] == .bool(true)
        // Match ordinary serving exactly: explicit text-only ignores the
        // optional codec; otherwise a present-invalid sidecar is NOT absence.
        let presence: MiMoV26OrdinaryServingPolicy.SidecarPresence?
        if languageOnly { presence = nil }
        else { presence = try MiMoV26OrdinaryServingPolicy.sidecarPresence(root: root) }
        let audio: MiMoV26AudioSidecarLoadSession?
        if presence == .present {
            audio = try MiMoV26AudioSidecarLoadSession(root: root,
                mainConfiguration: configuration,
                mainConfigurationSHA256: main.request.binding.configSHA256,
                isCancelled: { Task.isCancelled })
        } else { audio = nil }

        let stored = try payloadInventory(root: root)
        var expected = Dictionary(uniqueKeysWithValues: main.plan.shards.map {
            ($0.name, UInt64($0.objectState.bytes))
        })
        let sidecarName = "audio_tokenizer/model.safetensors"
        if let audio {
            expected[sidecarName] = UInt64(audio.request.fileBytes)
        } else if languageOnly, let ignored = stored[sidecarName] {
            // It is stored but not installed by this ordinary text-only mode.
            // Keep it in the wire/source size and require a positive full LOAD
            // supplement; never synthesize an SSD-offload declaration for it.
            expected[sidecarName] = ignored
        }
        guard stored == expected, try checkedSum(stored.values) == sizeBytes else {
            throw Refusal.inventory
        }
        let total = try checkedAdd(main.request.requiredLoadBytes, audio?.request.requiredLoadBytes ?? 0)
        // The wire contract requires at least the native 1-GiB metadata floor
        // above the complete stored inventory. Unsupported extra assets or a
        // text-only inventory larger than this bound retain legacy pricing.
        guard total >= sizeBytes, total - sizeBytes >= 1 << 30 else { throw Refusal.inventory }
        try main.validateDescriptor()
        try audio?.validateSource()
        if !languageOnly {
            guard try MiMoV26OrdinaryServingPolicy.sidecarPresence(root: root) == presence else {
                throw Refusal.inventory
            }
        }
        guard try payloadInventory(root: root) == stored else { throw Refusal.inventory }
        try Task.checkCancellation()
        return .init(storedBytes: sizeBytes, mainLoadBytes: main.request.requiredLoadBytes,
            sidecarLoadBytes: audio?.request.requiredLoadBytes ?? 0, totalBytes: total,
            transientBytes: total - sizeBytes)
    }

    private static func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw Refusal.overflow }
        return result.partialValue
    }

    private static func checkedSum<S: Sequence>(_ values: S) throws -> UInt64 where S.Element == UInt64 {
        try values.reduce(0, checkedAdd)
    }

    /// Include hidden payloads too; the smaller quote must not overlook a
    /// second file that the public scanner's display enumeration did not count.
    /// No symlink traversal or non-regular payload is accepted for this quote.
    private static func payloadInventory(root: URL) throws -> [String: UInt64] {
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { throw Refusal.inventory }
        var result: [String: UInt64] = [:], visited = 0
        let prefix = root.path + "/"
        for case let entry as URL in entries {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 4096 else { throw Refusal.inventory }
            guard ["safetensors", "npz", "bin"].contains(entry.pathExtension) else {
                // Do not follow directory aliases into arbitrary inventory.
                if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    entries.skipDescendants()
                }
                continue
            }
            let file = entry.standardizedFileURL
            guard file.path.hasPrefix(prefix),
                  try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw Refusal.inventory
            }
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? UInt64, bytes > 0,
                  result.count < 128 else { throw Refusal.inventory }
            let relative = String(String.UnicodeScalarView(
                file.path.unicodeScalars.dropFirst(prefix.unicodeScalars.count)))
            guard result.updateValue(bytes, forKey: relative) == nil else { throw Refusal.inventory }
        }
        return result
    }
}
