import Foundation
import CryptoKit

/// Encoded still images and their exact causal prompt spans. This envelope
/// grants no model capability. No pixels, tensors, or URLs cross this boundary.
public struct ClusterStillImages: Codable, Equatable, Sendable {
    public static let maximumImages = 1
    public static let maximumEncodedBytes = 96 * 1024
    public static let maximumEnvelopeBytes = 135_000
    public static let maximumPixels = 1024 * 1024
    public static let maximumFeatures = 1024
    public static let glmProfileID = ClusterGLMImageCandidate.profileID
    public struct Image: Codable, Equatable, Sendable {
        public let png: Data
        public let width, height, tokenOffset, tokenCount: Int
        public init(png: Data, width: Int, height: Int, tokenOffset: Int, tokenCount: Int) {
            self.png = png; self.width = width; self.height = height
            self.tokenOffset = tokenOffset; self.tokenCount = tokenCount
        }
    }
    public let configurationSHA256: String
    public let images: [Image]
    public init(configurationSHA256: String, images: [Image]) {
        self.configurationSHA256 = configurationSHA256; self.images = images
    }
    public func validateStructure(promptCount: Int) throws {
        try workerRequire(configurationSHA256.utf8.count == 64 && configurationSHA256.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }, "Invalid still-image source identity")
        try workerRequire((1...Self.maximumImages).contains(images.count), "Invalid still-image count")
        var remaining = Self.maximumEncodedBytes, end = 0
        for image in images {
            try workerRequire(image.png.count > 32 && image.png.count <= remaining,
                "Encoded still-image byte bound exceeded")
            remaining -= image.png.count
            try workerRequire(image.png.prefix(8) == Data([137,80,78,71,13,10,26,10])
                && image.width > 0 && image.height > 0 && image.width <= Self.maximumPixels / image.height,
                "Invalid still-image PNG geometry")
            try workerRequire(image.tokenOffset > end && image.tokenCount > 0
                && image.tokenCount <= Self.maximumFeatures && image.tokenCount < promptCount
                && image.tokenOffset < promptCount - image.tokenCount, "Invalid still-image span")
            end = image.tokenOffset + image.tokenCount
        }
    }
    public func validate(prompt: [Int], imageToken: Int, startToken: Int, endToken: Int, videoToken: Int) throws {
        try validateStructure(promptCount: prompt.count)
        for image in images {
            let stop = image.tokenOffset + image.tokenCount
            try workerRequire(prompt[image.tokenOffset - 1] == startToken && prompt[stop] == endToken
                && prompt[image.tokenOffset..<stop].allSatisfy { $0 == imageToken }, "Unbound still-image span")
        }
        try workerRequire(!prompt.contains(videoToken)
            && prompt.filter { $0 == imageToken }.count == images.reduce(0) { $0 + $1.tokenCount },
            "Unowned media marker")
    }
    public static func decodeBounded(_ data: Data) throws -> Self {
        try workerRequire(!data.isEmpty && data.count <= maximumEnvelopeBytes, "Still-image envelope exceeds bound")
        try validateClusterWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterWorkerProtocolError.invalid("Still-image envelope must be an object")
        }
        var root = WorkerObject(object)
        let configuration = try root.string("configurationSHA256")
        let objects = try root.objects("images"); try root.finish()
        try workerRequire((1...maximumImages).contains(objects.count), "Invalid still-image count")
        var images: [Image] = [], remaining = maximumEncodedBytes
        for object in objects {
            var item = WorkerObject(object)
            let encoded = try item.string("png")
            try workerRequire(encoded.utf8.count <= (remaining + 2) / 3 * 4, "Still-image base64 bound")
            guard let png = Data(base64Encoded: encoded), png.count <= remaining else {
                throw ClusterWorkerProtocolError.invalid("Invalid still-image encoding")
            }
            let image = try Image(png: png, width: item.int("width"), height: item.int("height"),
                tokenOffset: item.int("tokenOffset"), tokenCount: item.int("tokenCount"))
            try item.finish(); remaining -= png.count; images.append(image)
        }
        return .init(configurationSHA256: configuration, images: images)
    }
    public var fingerprint: String {
        var hash = SHA256()
        hash.update(data: Data(("cluster-still-images-v1|" + configurationSHA256).utf8))
        func integer(_ value: Int) {
            var n = UInt64(bitPattern: Int64(value)).bigEndian
            withUnsafeBytes(of: &n) { hash.update(data: Data($0)) }
        }
        integer(images.count)
        for image in images {
            for n in [image.width, image.height, image.tokenOffset, image.tokenCount, image.png.count] { integer(n) }
            hash.update(data: image.png)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
