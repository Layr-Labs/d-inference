import CryptoKit
import Foundation

/// Binds the processor metadata consumed by the pinned VLM factory. That
/// factory accepts either processor file and merges both when both exist.
/// Reading bounded bytes here never retains an image, prompt or model tensor.
enum GemmaVisionProcessorIdentity {
    static func fingerprint(directory: URL, device: String) -> String? {
        var digest = SHA256()
        digest.update(data: Data("Gemma4Processor/sRGB/orientation/resize-v1;gemma-image-adapter-v1".utf8))
        digest.update(data: Data(device.utf8))
        var processorFiles = 0
        for name in ["config.json", "preprocessor_config.json", "processor_config.json"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if name == "config.json" { return nil }
                digest.update(data: Data("absent:\(name)".utf8))
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let bytes = try? handle.read(upToCount: 64 * 1024 + 1),
                bytes.count <= 64 * 1024 else { return nil }
            digest.update(data: Data(name.utf8))
            digest.update(data: Data(SHA256.hash(data: bytes)))
            if name != "config.json" { processorFiles += 1 }
        }
        // A factory fallback without processor metadata is unqualified here.
        guard processorFiles > 0 else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
