import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite struct GLM5NextCalibrationBindingWireTests {
    @Test func expectedVocabularyComesFromExactPinnedBytes() throws {
        let bytes = Data(#"{"text_config":{"vocab_size":512},"unrelated":true}"#.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try GLM5NextCalibrationBinding.configurationVocabulary(bytes, expectedSHA256: hash) == 512)
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationBinding.configurationVocabulary(bytes + Data([10]), expectedSHA256: hash)
        }
        for source in [#"{"vocab_size":512}"#, #"{"text_config":{"vocab_size":0}}"#,
                       #"{"text_config":{"vocab_size":512.5}}"#, #"{"text_config":{"vocab_size":true}}"#] {
            let value = Data(source.utf8)
            let digest = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
            #expect(throws: (any Error).self) {
                try GLM5NextCalibrationBinding.configurationVocabulary(value, expectedSHA256: digest)
            }
        }
    }

    /// Consumes the actual worker metadata API's export, never a fabricated plan.
    /// Optional for ordinary CPU suites; mandatory in the parent's wire gate.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_FIXTURE"] != nil
        || ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
    func actualWorkerBindingUsesExactClosedProviderWire() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DARKBLOOM_GLM_METADATA_BINDING_FIXTURE"] else {
            Issue.record("Required worker-derived metadata binding fixture is absent")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let binding = try JSONDecoder().decode(GLM5NextCalibrationBinding.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let canonical = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        #expect(NSDictionary(dictionary: object).isEqual(to: canonical))
        #expect(GLM5NextCalibrationDocument.hashSyntax(binding.executionPlanSHA256))
        #expect(binding.profile.vocabularySize > 0)
    }
}
