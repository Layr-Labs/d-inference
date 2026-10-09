import Foundation
import CryptoKit

/// A host key from a known-hosts file, as its algorithm and the fingerprint
/// `ssh-keygen -l` prints for it. The host names in the file are not kept.
public struct ClusterConsoleHostKey: Encodable, Sendable, Equatable {
    public let algorithm: String
    /// `SHA256:` followed by the unpadded base64 of the key blob's digest.
    public let fingerprint: String
}

enum ClusterConsoleHostKeys {
    /// More keys than a two-Mac setup pins; a longer file is summarized by its first entries.
    static let maximumKeys = 8

    /// Reads `[marker] hosts algorithm base64-key [comment]` lines. A line it
    /// cannot read is skipped: this is a description of the pinned file, and
    /// the pin itself, not this reader, is what trust rests on.
    static func fingerprints(knownHosts text: String) -> [ClusterConsoleHostKey] {
        var keys = [ClusterConsoleHostKey]()
        for line in text.split(whereSeparator: \.isNewline) {
            var fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            if first.hasPrefix("@") { fields.removeFirst() }
            guard fields.count >= 3, let blob = Data(base64Encoded: String(fields[2])), !blob.isEmpty else { continue }
            let algorithm = String(fields[1])
            guard algorithm.utf8.count <= 64, algorithm.utf8.allSatisfy({ (33...126).contains($0) }) else { continue }
            let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let key = ClusterConsoleHostKey(algorithm: algorithm, fingerprint: "SHA256:" + digest)
            if !keys.contains(key) { keys.append(key) }
            if keys.count == maximumKeys { break }
        }
        return keys
    }
}

/// What the saved trust inputs look like on this Mac right now.
public struct ClusterConsoleTrust: Encodable, Sendable, Equatable {
    public let knownHostsPinSHA256: String
    /// Nil when the pinned file could not be read; `error` says why.
    public let knownHostsPinMatches: Bool?
    public let hostKeys: [ClusterConsoleHostKey]
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
        var matches: Bool?, keys = [ClusterConsoleHostKey]()
        do {
            let hosts = try ClusterConfigurationFiles.read(URL(fileURLWithPath: trust.knownHostsFile), maximum: 64 * 1024)
            matches = ClusterConfigurationCodec.sha256(hosts) == trust.knownHostsSHA256
            keys = fingerprints(of: hosts)
        } catch {
            problems.append("known-hosts file: " + ClusterConsoleText.bounded(error))
        }
        return .init(knownHostsPinSHA256: trust.knownHostsSHA256, knownHostsPinMatches: matches, hostKeys: keys,
            identityFileUsable: identityUsable, error: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }

    private static func fingerprints(of hosts: Data) -> [ClusterConsoleHostKey] {
        String(data: hosts, encoding: .utf8).map(ClusterConsoleHostKeys.fingerprints(knownHosts:)) ?? []
    }
}
