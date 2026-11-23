import Foundation

/// The coordinator's copy of one dispatch attempt's prefix-cache identity,
/// carried inside the sealed request body as `_darkbloom_cache`. It holds the
/// attempt's receipt nonce, so it applies only to the attempt whose frame
/// carries the same `cache_receipt_nonce`: a copy without that nonce (another
/// attempt's, or one the caller wrote) never selects a cache scope.
struct SealedPrefixCacheMetadata: Sendable, Equatable {
    let receiptNonce: String
    let scope: String
    /// Coordinator-observed repeat demand, as `cache_repeated_prefix_tokens`.
    let repeatedPrefixTokens: Int?

    /// The `_darkbloom_cache` member of a decoded request body. A missing or
    /// malformed member, or one with a blank nonce or scope, has no `value`.
    /// `cachePolicy` is read on its own: it needs no nonce or scope, and a
    /// member without this attempt's nonce still narrows the request to
    /// `memoryOnly`, because a narrower policy only gives up cache reuse.
    struct BodyProbe: Decodable {
        let value: SealedPrefixCacheMetadata?
        let cachePolicy: RequestCachePolicy

        private enum CodingKeys: String, CodingKey {
            case member = "_darkbloom_cache"
        }

        private struct Member: Decodable {
            let nonce: String
            let scope: String
            let repeatedPrefixTokens: Int?

            enum CodingKeys: String, CodingKey {
                case nonce, scope
                case repeatedPrefixTokens = "repeated_prefix_tokens"
            }
        }

        /// An absent `cache_policy` is `default`; any present value but the
        /// string `"default"` (another string, `null`, a number, an object)
        /// is `memoryOnly`.
        private struct PolicyMember: Decodable {
            let policy: RequestCachePolicy

            enum CodingKeys: String, CodingKey { case cachePolicy = "cache_policy" }

            init(from decoder: any Decoder) throws {
                policy = RequestCachePolicy(
                    decoding: try decoder.container(keyedBy: CodingKeys.self), forKey: .cachePolicy)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A member that is present but not an object has an unreadable
            // policy, so it is `memoryOnly` too.
            if container.contains(.member) {
                cachePolicy = (try? container.decode(PolicyMember.self, forKey: .member))?.policy ?? .memoryOnly
            } else {
                cachePolicy = .default
            }
            guard let member = try? container.decode(Member.self, forKey: .member),
                Self.nonBlank(member.nonce),
                Self.nonBlank(member.scope)
            else {
                value = nil
                return
            }
            value = SealedPrefixCacheMetadata(
                receiptNonce: member.nonce,
                scope: member.scope,
                repeatedPrefixTokens: member.repeatedPrefixTokens.map { max(0, $0) })
        }

        private static func nonBlank(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension RemotePrefixCacheContext {
    /// This attempt's context with the sealed copy's scope, and its repeat
    /// demand when it carries one, in place of the frame's, when the copy
    /// carries this attempt's receipt nonce. Otherwise the frame's values
    /// stand, as from a coordinator that writes no sealed copy.
    func applying(sealed: SealedPrefixCacheMetadata?) -> RemotePrefixCacheContext {
        guard let sealed, let receiptNonce, sealed.receiptNonce == receiptNonce else { return self }
        return RemotePrefixCacheContext(
            cacheScope: sealed.scope,
            cacheReceiptNonce: receiptNonce,
            repeatedPrefixTokens: sealed.repeatedPrefixTokens ?? repeatedPrefixTokens)
    }
}
