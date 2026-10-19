import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterProtocol

/// Closed wire claim only. The worker derives it with GLM5NextCalibration.binding
/// from validated metadata, and rederives it before LOAD. No provider plan math.
struct GLM5NextCalibrationBinding: Codable, Equatable {
    struct Profile: Codable, Equatable {
        let id: String
        let vocabularySize: Int
        let maximumPromptTokens: Int
        let maximumOutputTokens: Int
        let maximumChunkTokens: Int
        let maximumContextTokens: Int

        init(id: String, vocabularySize: Int, maximumPromptTokens: Int,
             maximumOutputTokens: Int, maximumChunkTokens: Int, maximumContextTokens: Int) {
            self.id = id; self.vocabularySize = vocabularySize
            self.maximumPromptTokens = maximumPromptTokens; self.maximumOutputTokens = maximumOutputTokens
            self.maximumChunkTokens = maximumChunkTokens; self.maximumContextTokens = maximumContextTokens
        }
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, vocabularySize, maximumPromptTokens, maximumOutputTokens, maximumChunkTokens, maximumContextTokens
        }
        init(from decoder: Decoder) throws {
            try GLM5NextCalibrationBinding.requireKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            vocabularySize = try c.decode(Int.self, forKey: .vocabularySize)
            maximumPromptTokens = try c.decode(Int.self, forKey: .maximumPromptTokens)
            maximumOutputTokens = try c.decode(Int.self, forKey: .maximumOutputTokens)
            maximumChunkTokens = try c.decode(Int.self, forKey: .maximumChunkTokens)
            maximumContextTokens = try c.decode(Int.self, forKey: .maximumContextTokens)
        }
        var workerProfile: ClusterWorkerProfile {
            .init(id: id, vocabularySize: vocabularySize, maximumPromptTokens: maximumPromptTokens,
                maximumOutputTokens: maximumOutputTokens, maximumChunkTokens: maximumChunkTokens,
                maximumContextTokens: maximumContextTokens)
        }
    }
    let profile: Profile
    let executionPlanSHA256: String

    init(profile: Profile, executionPlanSHA256: String) {
        self.profile = profile; self.executionPlanSHA256 = executionPlanSHA256
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case profile, executionPlanSHA256 }
    init(from decoder: Decoder) throws {
        try Self.requireKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(Profile.self, forKey: .profile)
        executionPlanSHA256 = try c.decode(String.self, forKey: .executionPlanSHA256)
    }
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard Set(c.allKeys.map(\.stringValue)) == expected else {
            throw GLM5NextCalibrationDocument.invalid("Missing or unknown calibration binding fields")
        }
    }
    func validate(profileID: String, vocabularySize: Int, prompt: Int, output: Int,
                  chunk: Int, context: Int) throws {
        guard vocabularySize > 0, vocabularySize <= Int(Int32.max),
              profile == Profile(id: profileID, vocabularySize: vocabularySize,
                  maximumPromptTokens: prompt, maximumOutputTokens: output,
                  maximumChunkTokens: chunk, maximumContextTokens: context),
              GLM5NextCalibrationDocument.hashSyntax(executionPlanSHA256) else {
            throw GLM5NextCalibrationDocument.invalid("Calibration binding differs from requested profile or pinned configuration")
        }
    }

    /// Read the vocabulary from the pinned bytes, never from the returned claim.
    /// Full GLM schema/model validation remains in the native descriptor.
    static func configurationVocabulary(_ bytes: Data, expectedSHA256: String) throws -> Int {
        guard !bytes.isEmpty, bytes.count <= 32 << 20,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw GLM5NextCalibrationDocument.invalid("Configuration bytes differ from the pinned identity")
        }
        struct Configuration: Decodable {
            struct Text: Decodable { let vocab_size: Int }
            let text_config: Text
        }
        let size = try JSONDecoder().decode(Configuration.self, from: bytes).text_config.vocab_size
        guard size > 0, size <= Int(Int32.max) else {
            throw GLM5NextCalibrationDocument.invalid("Invalid pinned configuration vocabulary")
        }
        return size
    }

    static func configurationVocabulary(at url: URL, expectedSHA256: String, deadline: UInt64) throws -> Int {
        let maximum = 32 << 20
        let identity = try DistributedInstalledFiles.verify(url, expectedSHA256: expectedSHA256,
            maximumBytes: maximum, deadline: deadline)
        let parent = try ClusterConfigurationFiles.directory(url.deletingLastPathComponent())
        defer { Darwin.close(parent.descriptor) }
        let fd = openat(parent.descriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GLM5NextCalibrationDocument.invalid("Cannot read pinned configuration") }
        defer { Darwin.close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              DistributedInstalledFiles.unsafeReason(information, maximumBytes: maximum, executable: false) == nil else {
            throw GLM5NextCalibrationDocument.invalid("Pinned configuration is not a safe regular input")
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            try DistributedInstalledFiles.check(deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, count <= maximum - bytes.count else {
                throw GLM5NextCalibrationDocument.invalid("Configuration read exceeded its bound")
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try DistributedInstalledFiles.check(deadline)
        try identity.requireUnchanged(); try parent.check()
        return try configurationVocabulary(bytes, expectedSHA256: expectedSHA256)
    }
}
