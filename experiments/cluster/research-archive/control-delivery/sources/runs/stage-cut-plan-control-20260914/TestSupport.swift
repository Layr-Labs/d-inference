import Foundation
import CryptoKit

// Exact supporting definitions extracted from Options.swift and ModelLoading.swift.
struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
