import Foundation
import CryptoKit

/// A key from a known-hosts file, as its algorithm and the fingerprint
/// `ssh-keygen -l` prints for it. The host names in the file are not kept.
public struct ClusterConsoleHostKey: Encodable, Sendable, Equatable {
    /// What the file says the key is for.
    public enum Kind: String, Encodable, Sendable {
        /// A key a host is accepted by.
        case host
        /// A certificate authority whose signed host keys are accepted.
        case certificateAuthority
        /// A key that is refused.
        case revoked
    }
    public let kind: Kind
    public let algorithm: String
    /// `SHA256:` followed by the unpadded base64 of the key blob's digest.
    public let fingerprint: String
}

enum ClusterConsoleHostKeys {
    /// More keys than a two-Mac setup pins; a longer file is shown by its first entries and a count.
    static let maximumKeys = 8

    /// Reads `[marker] hosts algorithm base64-key [comment]` lines. A line it
    /// cannot read is skipped: this is a description of the pinned file, and
    /// the pin itself, not this reader, is what trust rests on. `notShown`
    /// counts the distinct keys beyond the first `maximumKeys`.
    static func fingerprints(knownHosts text: String) -> (keys: [ClusterConsoleHostKey], notShown: Int) {
        var keys = [ClusterConsoleHostKey]()
        for line in text.split(whereSeparator: \.isNewline) {
            var fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            var kind = ClusterConsoleHostKey.Kind.host
            if first.hasPrefix("@") {
                switch first {
                case "@cert-authority": kind = .certificateAuthority
                case "@revoked": kind = .revoked
                default: continue
                }
                fields.removeFirst()
            }
            guard fields.count >= 3, let blob = Data(base64Encoded: String(fields[2])), !blob.isEmpty else { continue }
            let algorithm = String(fields[1])
            guard algorithm.utf8.count <= 64, algorithm.utf8.allSatisfy({ (33...126).contains($0) }) else { continue }
            let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let key = ClusterConsoleHostKey(kind: kind, algorithm: algorithm, fingerprint: "SHA256:" + digest)
            if !keys.contains(key) { keys.append(key) }
        }
        return (Array(keys.prefix(maximumKeys)), max(keys.count - maximumKeys, 0))
    }
}

/// What the saved trust inputs look like on this Mac right now.
public struct ClusterConsoleTrust: Encodable, Sendable, Equatable {
    public let knownHostsPinSHA256: String
    /// Nil when the pinned file could not be read; `error` says why.
    public let knownHostsPinMatches: Bool?
    public let hostKeys: [ClusterConsoleHostKey]
    /// Further distinct keys in the pinned file that are not listed.
    public let hostKeysNotShown: Int
    /// The identity file exists, is a regular file and is owner-only. Its contents are never read.
    public let identityFileUsable: Bool
    public let error: String?

    /// The same two checks saving a setup makes, without the save.
    static func observe(_ trust: ClusterConfiguration.Trust) -> ClusterConsoleTrust {
        var problems = [String]()
        var identityUsable = true
        do { try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: trust.identityFile), privateMode: true) } catch {
            identityUsable = false
            problems.append("identity file: " + ClusterConsoleText.bounded(error))
        }
        var matches: Bool?, listed = (keys: [ClusterConsoleHostKey](), notShown: 0)
        do {
            let hosts = try ClusterConfigurationFiles.read(URL(fileURLWithPath: trust.knownHostsFile), maximum: 64 * 1024)
            matches = ClusterConfigurationCodec.sha256(hosts) == trust.knownHostsSHA256
            if let text = String(data: hosts, encoding: .utf8) { listed = ClusterConsoleHostKeys.fingerprints(knownHosts: text) }
        } catch {
            problems.append("known-hosts file: " + ClusterConsoleText.bounded(error))
        }
        return .init(knownHostsPinSHA256: trust.knownHostsSHA256, knownHostsPinMatches: matches, hostKeys: listed.keys,
            hostKeysNotShown: listed.notShown, identityFileUsable: identityUsable,
            error: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }
}
