import Foundation
import CryptoKit

/// Private draft wire profile. This name is not a catalog or qualification grant.
/// Encoded pixels, never caller-provided embeddings. No image decoder or MLX here.
public struct ClusterMiMoImages: Codable, Equatable, Sendable {
    public static let profileSuffix = "_image_draft_v1"
    public static let maximumImages = ClusterMiMoImageCandidate.maximumImages
    public static let maximumEncodedBytes = ClusterMiMoImageCandidate.maximumEncodedBytes
    public static let maximumPixels = ClusterMiMoImageCandidate.maximumSourcePixels
    public struct Image: Codable, Equatable, Sendable {
        public let png: Data
        public let width, height, tokenOffset, tokenCount: Int
        public init(png: Data, width: Int, height: Int, tokenOffset: Int, tokenCount: Int) {
            self.png = png; self.width = width; self.height = height
            self.tokenOffset = tokenOffset; self.tokenCount = tokenCount
        }
    }
    public let images: [Image]
    public init(images: [Image]) { self.images = images }

    /// Structural checks before either rank is reserved. Actual codec metadata
    /// and SDK geometry are independently checked by ingress and each worker.
    public func validate(prompt: [Int], imageToken: Int = 151655,
                         startToken: Int = 151652, endToken: Int = 151653) throws {
        try workerRequire((1...Self.maximumImages).contains(images.count), "Invalid MiMo image count")
        var bytes = 0, end = 0
        let signature = Data([137,80,78,71,13,10,26,10])
        for image in images {
            let n = image.png.count
            try workerRequire(n > 32 && n <= Self.maximumEncodedBytes - bytes,
                "MiMo encoded image limit")
            bytes += n
            try workerRequire(image.png.prefix(8) == signature && image.width > 0 && image.height > 0
                && image.width <= Self.maximumPixels / image.height, "Invalid MiMo PNG geometry")
            try workerRequire(image.tokenOffset > end && image.tokenCount > 0
                && image.tokenCount < prompt.count
                && image.tokenOffset < prompt.count - image.tokenCount, "Invalid MiMo image positions")
            let stop = image.tokenOffset + image.tokenCount
            try workerRequire(prompt[image.tokenOffset - 1] == startToken && prompt[stop] == endToken
                && prompt[image.tokenOffset..<stop].allSatisfy({ $0 == imageToken }), "Unbound MiMo image span")
            end = stop
        }
        // A raw reserved image marker outside the owned spans is not text.
        let covered = images.reduce(0) { $0 + $1.tokenCount }
        try workerRequire(prompt.filter { $0 == imageToken }.count == covered, "Unowned MiMo image marker")
    }
    public static func decodeBounded(_ data: Data) throws -> Self {
        try workerRequire(!data.isEmpty && data.count <= 135_000,"MiMo envelope exceeds bound")
        try validateClusterWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw ClusterWorkerProtocolError.invalid("MiMo envelope must be an object")
        }
        var root = WorkerObject(object)
        let objects = try root.objects("images");try root.finish()
        try workerRequire((1...maximumImages).contains(objects.count),"MiMo image count")
        var images:[Image] = [], remaining = maximumEncodedBytes
        for object in objects {
            var image = WorkerObject(object)
            let encoded = try image.string("png")
            try workerRequire(encoded.utf8.count <= (remaining+2)/3*4,"MiMo base64 limit")
            guard let png = Data(base64Encoded:encoded), png.count <= remaining else {
                throw ClusterWorkerProtocolError.invalid("Invalid MiMo base64")
            }
            let value = try Image(png:png,width:image.int("width"),height:image.int("height"),
                tokenOffset:image.int("tokenOffset"),tokenCount:image.int("tokenCount"))
            try image.finish();remaining -= png.count;images.append(value)
        }
        return .init(images:images)
    }
    public var encodedBytes: Int { images.reduce(0) { $0 + $1.png.count } }
    public var fingerprint: String {
        // Explicit length-prefixed binary identity, independent of JSON ordering.
        var hash = SHA256()
        func integer(_ value: Int) {
            var word = UInt64(bitPattern:Int64(value)).bigEndian
            withUnsafeBytes(of: &word) { hash.update(data: Data($0)) }
        }
        hash.update(data: Data("mimo-cluster-png-causal-v1".utf8)); integer(images.count)
        for image in images {
            for n in [image.width,image.height,image.tokenOffset,image.tokenCount,image.png.count] { integer(n) }
            hash.update(data: image.png)
        }
        return hash.finalize().map { String(format: "%02x",$0) }.joined()
    }
}
