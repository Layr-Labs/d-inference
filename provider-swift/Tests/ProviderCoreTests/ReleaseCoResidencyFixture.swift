import CryptoKit
import Foundation
import ProviderCoreFoundation
@testable import ProviderCore

/// Externally frozen inputs; the test neither downloads nor aliases checkpoints.
struct ReleaseCoResidencyFixture: Decodable, Sendable {
    static let modelIDs = ["qwen3.6-35b-a3b-vl-mtp-mxfp8", "gpt-oss-20b", "gemma-4-26b-qat-4bit"]
    static let aggregates = [
        "d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed",
        "61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512",
        "2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785",
    ]
    struct Prompt: Decodable, Sendable {
        let request: ChatCompletionRequest
        let tokens: [Int]
        /// SHA256 of signed Int32 little-endian token IDs, without a header.
        let tokenSHA256: String
    }
    struct Model: Decodable, Sendable {
        let modelID: String
        let directory: String
        let aggregateSHA256: String
        let recovery: Prompt
    }
    let models: [Model]
    let streaming: Prompt
    let cacheRoot: String
    let outputPath: String
    let metallibPath: String
    let metallibSHA256: String
    let memoryReserveGiB: UInt64
    /// Optional existing operator cap; never changes physical hardware facts.
    let memoryCapFraction: String?

    static func read() throws -> (Self, String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DARKBLOOM_RELEASE_CORESIDENCY_CONFIG"],
              let expected = env["DARKBLOOM_RELEASE_CORESIDENCY_CONFIG_SHA256"] else {
            throw ReleaseCoResidencyFailure("explicit fixture path and SHA256 required")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = hash(data)
        try require(digest == expected, "fixture changed after review")
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        try fixture.validate(environment: env)
        return (fixture, digest)
    }

    func validate(environment env: [String: String]) throws {
        try Self.require(models.map(\.modelID) == Self.modelIDs, "exact ordered three-model cohort required")
        try Self.require(memoryReserveGiB >= 4 && memoryReserveGiB <= 32, "invalid operator reserve")
        try Self.require(env["DARKBLOOM_MEM_CAP_FRACTION"] == memoryCapFraction, "operator cap differs from fixture")
        if let memoryCapFraction {
            guard let fraction = Double(memoryCapFraction), fraction.isFinite, (0.5...0.9).contains(fraction) else {
                throw ReleaseCoResidencyFailure("bounded real operator cap required")
            }
        }
        for key in ["DARKBLOOM_PREFIX_CACHE", "DARKBLOOM_PREFIX_CACHE_MEMORY", "DARKBLOOM_CBV2_PAGED_KV", "DARKBLOOM_ACTIVATION_RESERVE_GB"] {
            try Self.require(env[key] == nil, "unset serving override required: \(key)")
        }
        try Self.require(env["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"] == "1"
            && env["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] == "0"
            && env["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"] == cacheRoot, "isolated ephemeral SSD context required")
        let root = URL(fileURLWithPath: cacheRoot, isDirectory: true)
        let output = URL(fileURLWithPath: outputPath)
        try Self.require(cacheRoot.hasPrefix("/") && root.standardizedFileURL.resolvingSymlinksInPath().path == cacheRoot,
                         "canonical owned cache root required")
        try Self.require(!FileManager.default.fileExists(atPath: cacheRoot), "fresh empty SSD namespace required")
        let protected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/darkbloom").path
        try Self.require(!cacheRoot.hasPrefix(protected) && !protected.hasPrefix(cacheRoot), "normal cache roots prohibited")
        try Self.require(outputPath.hasPrefix("/") && output.standardizedFileURL.resolvingSymlinksInPath().path == outputPath
            && !FileManager.default.fileExists(atPath: outputPath), "fresh canonical report path required")
        for (index, model) in models.enumerated() {
            try Self.require(model.aggregateSHA256 == Self.aggregates[index], "exact release artifact required")
            try Self.validate(model.recovery, modelID: model.modelID, maximumOutput: 128)
        }
        try Self.validate(streaming, modelID: Self.modelIDs[0], maximumOutput: 8192)
        try Self.require(streaming.tokens == models[0].recovery.tokens,
                         "Qwen recovery must donate the exact subsequent streaming prefix")
        try Self.require((streaming.request.max_tokens ?? 0) >= 1024, "long ordinary stream required for measured overlap")
    }

    func modelInfos() throws -> [ModelInfo] {
        try models.map { model in
            guard let info = ModelScanner.parseModelInfo(
                snapshotDir: URL(fileURLWithPath: model.directory), modelName: model.modelID) else {
                throw ReleaseCoResidencyFailure("actual scanner metadata unavailable")
            }
            return info
        }
    }

    func verifyModels() throws {
        for model in models {
            let expected = URL(fileURLWithPath: model.directory).standardizedFileURL.resolvingSymlinksInPath()
            guard let selected = ModelScanner.resolveLocalPath(modelID: model.modelID) else {
                throw ReleaseCoResidencyFailure("audited model unavailable: \(model.modelID)")
            }
            try Self.require(selected.resolvingSymlinksInPath() == expected, "scanner selected a different snapshot")
            try Self.require(WeightHasher.computeHash(snapshotDir: selected, modelID: model.modelID) == model.aggregateSHA256,
                             "audited aggregate differs: \(model.modelID)")
        }
    }

    private static func validate(_ prompt: Prompt, modelID: String, maximumOutput: Int) throws {
        try require(prompt.request.model == modelID && prompt.request.temperature == 0
            && prompt.request.tools == nil && prompt.request.logit_bias == nil,
                    "ordinary greedy text request required")
        try require((1...maximumOutput).contains(prompt.request.max_tokens ?? 0)
            && (1...32768).contains(prompt.tokens.count), "bounded input/output required")
        var bytes = Data()
        for token in prompt.tokens {
            guard let value = Int32(exactly: token), value >= 0 else { throw ReleaseCoResidencyFailure("invalid token ID") }
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        try require(hash(bytes) == prompt.tokenSHA256, "canonical prompt-token digest differs")
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ReleaseCoResidencyFailure(message) }
    }
}

struct ReleaseCoResidencyFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
