import Foundation
import CryptoKit

/// Encoded Qwen/Bonsai media for a tensor-parallel request. The leader uses
/// the artifact's ordinary processor; rank 0 must reproduce its patches and
/// run the real vision tower. Both ranks reproduce the request's three-axis
/// MRoPE positions. No caller-provided feature tensor is accepted.
public struct ClusterQwenMedia: Equatable, Sendable {
    public static let contract = "qwen35_tp_media_v1"
    public static let maximumImages = 16
    public static let maximumVideos = 8
    public static let maximumEncodedBytes = 32 * 1024 * 1024
    public static let maximumEnvelopeBytes = (maximumEncodedBytes + 2) / 3 * 4 + 1024 * 1024
    public static let maximumItemPixels = 100_000_000
    public static let maximumKindPixels = 384_000_000
    public static let patchWidth = 3 * 2 * 16 * 16

    public enum Kind: String, Sendable { case image, video }
    /// The processor implementation and resolved configuration are bound;
    /// artifact/configuration identity also fixes the Bonsai 9B policy branch.
    public enum ProcessorPolicy: String, Sendable {
        case qwen35 = "qwen35-media-preparation-v1"
    }

    public struct Item: Equatable, Sendable {
        public let kind: Kind
        public let sha256: String
        public let byteCount: Int
        /// Source raster bound verified from encoded metadata before decoding.
        /// Video uses the largest coded/natural frame, not its resized grid.
        public let decodedPixels: Int
        /// Present only on rank 0's local reservation; rank 1 receives digests.
        public let encoded: Data?
        public let temporal, height, width: Int
        /// One contiguous placeholder run per item, including every video frame.
        public let tokenOffset, tokenCount: Int
        /// Canonical row-major float32 prepared patches, before any tower work.
        public let patchesSHA256: String

        public init(kind: Kind, sha256: String, byteCount: Int, decodedPixels: Int, encoded: Data?,
                    temporal: Int, height: Int, width: Int, tokenOffset: Int,
                    tokenCount: Int, patchesSHA256: String) {
            self.kind = kind; self.sha256 = sha256; self.byteCount = byteCount
            self.decodedPixels = decodedPixels
            self.encoded = encoded; self.temporal = temporal; self.height = height; self.width = width
            self.tokenOffset = tokenOffset; self.tokenCount = tokenCount; self.patchesSHA256 = patchesSHA256
        }
        public var withoutEncodedBytes: Self {
            .init(kind: kind, sha256: sha256, byteCount: byteCount, decodedPixels: decodedPixels, encoded: nil,
                temporal: temporal, height: height, width: width, tokenOffset: tokenOffset,
                tokenCount: tokenCount, patchesSHA256: patchesSHA256)
        }
    }

    public let artifactSHA256, configurationSHA256, processorSHA256: String
    public let processorPolicy: ProcessorPolicy
    public let promptLength: Int
    /// Canonical little-endian Int32 token IDs, including expanded placeholders.
    public let promptSHA256: String
    /// Canonical little-endian Int32 positions in [3, 1, promptLength] order.
    public let positionIDsSHA256: String
    public let decodeDeltas: [Int32]
    /// Processor order: images in prompt order, then videos in prompt order.
    public let items: [Item]

    public init(artifactSHA256: String, configurationSHA256: String, processorSHA256: String,
                processorPolicy: ProcessorPolicy, promptLength: Int, promptSHA256: String,
                positionIDsSHA256: String, decodeDeltas: [Int32], items: [Item]) {
        self.artifactSHA256 = artifactSHA256; self.configurationSHA256 = configurationSHA256
        self.processorSHA256 = processorSHA256; self.processorPolicy = processorPolicy
        self.promptLength = promptLength; self.promptSHA256 = promptSHA256
        self.positionIDsSHA256 = positionIDsSHA256; self.decodeDeltas = decodeDeltas; self.items = items
    }

    public var withoutEncodedBytes: Self {
        .init(artifactSHA256: artifactSHA256, configurationSHA256: configurationSHA256,
            processorSHA256: processorSHA256, processorPolicy: processorPolicy, promptLength: promptLength,
            promptSHA256: promptSHA256, positionIDsSHA256: positionIDsSHA256, decodeDeltas: decodeDeltas,
            items: items.map(\.withoutEncodedBytes))
    }
    public var carriesEncodedBytes: Bool { items.contains { $0.encoded != nil } }

    public func validateStructure() throws {
        try workerRequire([artifactSHA256, configurationSHA256, processorSHA256, promptSHA256,
            positionIDsSHA256].allSatisfy(ClusterWorkerValidation.hash), "Invalid Qwen media identity")
        try workerRequire((1...ClusterWorkerLimits.wirePromptTokens).contains(promptLength)
            && decodeDeltas.count == 1, "Invalid Qwen media positions")
        let images = items.filter { $0.kind == .image }.count
        try workerRequire(!items.isEmpty && images <= Self.maximumImages
            && items.count - images <= Self.maximumVideos
            && items.prefix(images).allSatisfy { $0.kind == .image }, "Invalid Qwen media order or count")
        try workerRequire(!carriesEncodedBytes || items.allSatisfy { $0.encoded?.count == $0.byteCount },
            "Partial Qwen media payload")
        var encodedBytes = 0, featureTokens = 0, imagePixels = 0, videoPixels = 0
        for item in items {
            try workerRequire(ClusterWorkerValidation.hash(item.sha256)
                && ClusterWorkerValidation.hash(item.patchesSHA256)
                && item.byteCount > 0 && item.byteCount <= Self.maximumEncodedBytes - encodedBytes,
                "Invalid Qwen encoded media bound")
            encodedBytes += item.byteCount
            let priorPixels = item.kind == .image ? imagePixels : videoPixels
            try workerRequire((1...Self.maximumItemPixels).contains(item.decodedPixels)
                && item.decodedPixels <= Self.maximumKindPixels - priorPixels, "Invalid Qwen source raster bound")
            if item.kind == .image { imagePixels += item.decodedPixels }
            else { videoPixels += item.decodedPixels }
            // Product video preprocessing samples at most eight frames and
            // patchifies pairs; a still image is one padded temporal pair.
            try workerRequire(item.temporal > 0 && item.temporal <= (item.kind == .image ? 1 : 4)
                && item.height > 0 && item.width > 0
                && item.height.isMultiple(of: 2) && item.width.isMultiple(of: 2), "Invalid Qwen media grid")
            let spatial = item.height.multipliedReportingOverflow(by: item.width)
            let patches = spatial.partialValue.multipliedReportingOverflow(by: item.temporal)
            try workerRequire(!spatial.overflow && !patches.overflow
                && patches.partialValue > 0 && patches.partialValue / 4 == item.tokenCount
                && item.tokenCount > 0 && item.tokenCount < promptLength
                && item.tokenCount <= promptLength - featureTokens, "Invalid Qwen media feature count")
            featureTokens += item.tokenCount
            try workerRequire(item.tokenOffset > 0 && item.tokenOffset < promptLength - item.tokenCount,
                "Invalid Qwen media span")
        }
        try workerRequire(featureTokens < promptLength, "Qwen media exceeds prompt")
        for kind in [Kind.image, .video] {
            let offsets = items.filter { $0.kind == kind }.map(\.tokenOffset)
            try workerRequire(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 },
                "Unordered Qwen media spans")
        }
        let ordered = items.sorted { $0.tokenOffset < $1.tokenOffset }
        try workerRequire(zip(ordered, ordered.dropFirst()).allSatisfy {
            $0.tokenOffset + $0.tokenCount < $1.tokenOffset
        }, "Overlapping Qwen media spans")
    }

    public func validate(prompt: [Int], imageToken: Int, videoToken: Int, startToken: Int,
                         endToken: Int, maximumPromptTokens: Int) throws {
        try validateStructure()
        try workerRequire(prompt.count == promptLength && promptLength <= maximumPromptTokens
            && Set([imageToken, videoToken, startToken, endToken]).count == 4
            && prompt.allSatisfy { (0..<ClusterWorkerLimits.vocabularySize).contains($0) },
            "Invalid Qwen media prompt")
        try workerRequire(Self.int32SHA256(prompt.map(Int32.init)) == promptSHA256, "Qwen media prompt differs")
        for item in items {
            let marker = item.kind == .image ? imageToken : videoToken
            let stop = item.tokenOffset + item.tokenCount
            try workerRequire(prompt[item.tokenOffset - 1] == startToken && prompt[stop] == endToken
                && prompt[item.tokenOffset..<stop].allSatisfy { $0 == marker }, "Unbound Qwen media span")
        }
        for (kind, marker) in [(Kind.image, imageToken), (Kind.video, videoToken)] {
            let covered = items.filter { $0.kind == kind }.reduce(0) { $0 + $1.tokenCount }
            try workerRequire(prompt.filter { $0 == marker }.count == covered, "Unowned Qwen media marker")
        }
    }

    public func verifyEncodedBytes() throws {
        try validateStructure()
        for item in items {
            guard let data = item.encoded else { throw ClusterWorkerProtocolError.invalid("Missing Qwen media bytes") }
            try workerRequire(Self.sha256(data) == item.sha256, "Qwen media bytes differ")
        }
    }

    /// Additional owners only; the caller must also reserve ordinary request
    /// state, decode/processor scratch and the live tower's actual workspaces.
    public struct Memory: Equatable, Sendable {
        public let encodedBytes, patchesBytes, positionBytes, featureBytes, largestTowerPatches: Int
    }
    public func memory(hiddenSize: Int, elementBytes: Int) throws -> Memory {
        try validateStructure()
        try workerRequire(hiddenSize > 0 && [2, 4].contains(elementBytes), "Invalid Qwen media feature dtype")
        let features = items.reduce(0) { $0 + $1.tokenCount }
        func multiply(_ a: Int, _ b: Int) throws -> Int {
            let n = a.multipliedReportingOverflow(by: b)
            try workerRequire(!n.overflow && n.partialValue > 0
                && n.partialValue <= ClusterWorkerLimits.capacityBytes, "Qwen media memory overflow")
            return n.partialValue
        }
        return try .init(encodedBytes: items.reduce(0) { $0 + $1.byteCount },
            patchesBytes: multiply(features, 4 * Self.patchWidth * 4),
            positionBytes: multiply(promptLength, 3 * MemoryLayout<Int32>.stride),
            featureBytes: multiply(multiply(features, hiddenSize), elementBytes),
            largestTowerPatches: items.map { $0.tokenCount * 4 }.max() ?? 0)
    }

    public var fingerprint: String {
        var hash = SHA256()
        func word(_ n: Int) { var v = UInt64(bitPattern: Int64(n)).bigEndian
            withUnsafeBytes(of: &v) { hash.update(data: Data($0)) } }
        for text in [Self.contract, artifactSHA256, configurationSHA256, processorSHA256,
                     processorPolicy.rawValue, promptSHA256, positionIDsSHA256] {
            word(text.utf8.count); hash.update(data: Data(text.utf8))
        }
        word(promptLength); word(decodeDeltas.count)
        for n in decodeDeltas { word(Int(n)) }
        word(items.count)
        for item in items {
            for text in [item.kind.rawValue, item.sha256, item.patchesSHA256] {
                word(text.utf8.count); hash.update(data: Data(text.utf8))
            }
            for n in [item.byteCount, item.decodedPixels, item.temporal, item.height, item.width, item.tokenOffset, item.tokenCount] { word(n) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func int32SHA256(_ values: [Int32]) -> String {
        var hash = SHA256()
        for value in values { var v = value.littleEndian
            withUnsafeBytes(of: &v) { hash.update(data: Data($0)) } }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

}
