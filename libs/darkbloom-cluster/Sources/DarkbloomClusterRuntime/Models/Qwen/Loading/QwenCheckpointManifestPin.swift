import Foundation

/// Optional exact raw-byte identity, separate from the unchanged aggregate and
/// file-descriptor verification. A nil expectation keeps legacy IO/hash work.
enum QwenCheckpointManifestPin {
    static func validateExpected(_ expected: String?) throws {
        if let expected {
            guard expected.utf8.count == 64,
                  expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ProbeError("Expected manifest must be a lowercase SHA256")
            }
        }
    }

    static func match(_ data: Data, expected: String?) throws -> String? {
        guard let expected else { return nil }
        try validateExpected(expected)
        guard data.count <= 4 * 1024 * 1024 else {
            throw ProbeError("Checkpoint manifest exceeds the 4 MiB metadata byte limit")
        }
        let actual = sha256(data)
        guard actual == expected else { throw ProbeError("Checkpoint raw manifest differs from expected SHA256") }
        return actual
    }
}
