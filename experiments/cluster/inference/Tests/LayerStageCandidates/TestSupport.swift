import CryptoKit
import Foundation

// These two definitions match the production helpers in Options.swift and
// ModelLoading.swift, whose complete files pull in unrelated native code.
struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func candidateRequire(_ value: Bool, _ message: String) throws {
    guard value else { throw ProbeError("Candidate metadata check: " + message) }
}

func candidateJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func candidateObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError("Candidate fixture requires an object")
    }
    return object
}
