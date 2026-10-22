import CryptoKit
import Foundation

/// The shared key of a prompt prefix at many frontiers in one pass over the
/// tokens. Each value equals `QwenStagePrefixCache.key(scope:tokens:)` for
/// `tokens[0..<frontier]`: the inner digest is the SHA-256 of the decimal
/// tokens joined by commas (`qwenGenerationTokenHash`), so one hasher fed in
/// order and copied at each frontier yields every inner digest.
enum QwenStagePrefixKeys {
    static func keys(scope: String, tokens: [Int], frontiers: Set<Int>) -> [Int: String] {
        let wanted = frontiers.filter { $0 > 0 && $0 <= tokens.count }.sorted()
        guard !wanted.isEmpty else { return [:] }
        var hasher = SHA256()
        var pending: [UInt8] = []
        pending.reserveCapacity(64 * 1024)
        var result: [Int: String] = [:]
        var index = 0
        for frontier in wanted {
            while index < frontier {
                if index > 0 { pending.append(0x2C) }
                pending.append(contentsOf: String(tokens[index]).utf8)
                index += 1
                if pending.count >= 60 * 1024 { hasher.update(data: pending); pending.removeAll(keepingCapacity: true) }
            }
            if !pending.isEmpty { hasher.update(data: pending); pending.removeAll(keepingCapacity: true) }
            let inner = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            result[frontier] = sha256(Data(("darkbloom-cluster-prefix-v1|" + scope + "|" + inner).utf8))
        }
        return result
    }
}
