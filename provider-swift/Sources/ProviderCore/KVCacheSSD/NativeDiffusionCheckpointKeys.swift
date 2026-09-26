import CryptoKit
import Foundation

/// Content identities for exact native encoder boundaries, not fixed AR blocks.
/// The store must still HMAC these digests, authenticate the complete checkpoint
/// and validate its native state/geometry before adoption. This helper retains
/// no prompt or model data and does not authorize a coordinator block anchor.
enum NativeDiffusionCheckpointKeys {
    enum Failure: Error { case invalidIdentity, invalidTokens, invalidPositions }

    static func hashes(tokens: [Int], positions: [Int], promptContractID: String,
                       scope: String) throws -> [Int: Data] {
        guard promptContractID.count == 64,
            promptContractID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            scope.utf8.count <= 4096 else { throw Failure.invalidIdentity }
        guard tokens.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }) else { throw Failure.invalidTokens }
        var previous = 0
        for position in positions {
            guard position > previous, position <= tokens.count else { throw Failure.invalidPositions }
            previous = position
        }
        var hash = SHA256()
        hash.update(data: Data("darkbloom.diffusion-native-prefix.v1".utf8))
        for text in [promptContractID, scope] {
            let bytes = Data(text.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        var result = [Int: Data]()
        var start = 0
        for end in positions {
            // Stream bounded pieces even if a donor asks for only its deepest
            // checkpoint. Do not materialize another full token-byte buffer.
            while start < end {
                let stop = start + min(512, end - start)
                var words = tokens[start..<stop].map { UInt32($0).bigEndian }
                words.withUnsafeMutableBytes { hash.update(data: Data($0)) }
                start = stop
            }
            let snapshot = hash
            result[end] = Data(snapshot.finalize())
        }
        return result
    }
}
