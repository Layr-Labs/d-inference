import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A one-attempt replacement capability, captured only for explicit login.
/// Raw bytes (including absent/empty metadata) are compared again at publication.
/// Nothing here authenticates, sends, or supplies an issuer for the old token.
struct ProviderCredentialRecovery: Sendable {
    let issuer: String
    private let files: [ProviderCredentialRecoveryFile]
    private let artifacts: [ProviderCredentialRecoveryArtifacts.Snapshot]

    static func prepare(for coordinatorURL: String) throws -> Self? {
        try ProviderCredentialProcessLock.withLock {
            let files = try snapshot()
            let incomplete = files[2].value != nil && (files[0].value == nil || files[1].value == nil)
            let interrupted: Bool
            if files[2].value == nil {
                interrupted = try ProviderCredentialRecoveryArtifacts.hasTokenBackup(canonicalPath: files[2].path)
            } else {
                interrupted = false
            }
            guard incomplete || interrupted else { return nil }
            let artifacts = try ProviderCredentialRecoveryArtifacts.capture(credentialPaths: files.map(\.path))

            let issuer = try canonicalCoordinatorIssuer(coordinatorURL)
            // Missing account metadata must not erase a known issuer binding.
            if let recordedIssuer = files[1].value,
               !providerCredentialIssuerMatches(recordedIssuer, expected: issuer) {
                throw ProviderCredentialStoreError.issuerMismatch(
                    expected: issuer,
                    actual: recordedIssuer
                )
            }
            return Self(issuer: issuer, files: files, artifacts: artifacts)
        }
    }

    func publish(token: String, accountID: String) throws {
        try publish(token: token, accountID: accountID, move: credentialRecoveryRename)
    }

    // Injectable file operation lets tests exercise rollback after a partial
    // publication without changing permissions on a user's credential directory.
    func publish(
        token: String,
        accountID: String,
        move: (URL, URL) throws -> Void
    ) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCredentialStoreError.missingToken
        }
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCredentialStoreError.missingAccountID
        }

        try ProviderCredentialProcessLock.withLock {
            try Task.checkCancellation()
            guard try Self.snapshot() == files,
                  try ProviderCredentialRecoveryArtifacts.capture(credentialPaths: files.map(\.path)) == artifacts
            else {
                throw ProviderCredentialStoreError.credentialChanged
            }
            try replace(with: [accountID, issuer, token], move: move)
            // Preserve all pre-existing evidence until a NEW authorized token
            // has committed. Never restore or authenticate with backup tokens.
            artifacts.forEach { $0.removeIfUnchanged() }
        }
    }

    private static func snapshot() throws -> [ProviderCredentialRecoveryFile] {
        try [
            ProviderAccountStore.accountPath(),
            ProviderIssuerStore.issuerPath(),
            AuthTokenStore.tokenPath(),
        ].map { try ProviderCredentialRecoveryFile(path: $0) }
    }

    /// Credential readers/publications use the credential lock. Stage every new file
    /// before changing any original, unpublish the old token first, and publish
    /// the new token last. Renamed originals retain their bytes and permissions
    /// for rollback; the old token is never paired with the new binding records.
    private func replace(
        with values: [String],
        move: (URL, URL) throws -> Void
    ) throws {
        let manager = FileManager.default
        let nonce = UUID().uuidString
        let staged = files.map { $0.path.appendingPathExtension("\(nonce).pending") }
        let backups = files.map { $0.path.appendingPathExtension("\(nonce).original") }
        defer {
            for path in staged { try? manager.removeItem(at: path) }
        }

        for index in files.indices {
            try manager.createDirectory(
                at: staged[index].deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Stage privately from creation; no credential reader observes
            // these files until their final rename under the lock.
            guard manager.createFile(
                atPath: staged[index].path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
            try Data(values[index].utf8).write(to: staged[index])
        }
        try Task.checkCancellation()

        var backedUp = Set<Int>()
        var published = Set<Int>()
        do {
            for index in files.indices.reversed() where files[index].data != nil {
                try Task.checkCancellation()
                try move(files[index].path, backups[index])
                backedUp.insert(index)
            }
            for index in files.indices {
                // This includes the final token publication. Cancellation
                // after any earlier rename must enter rollback, not strand
                // the originals or finish publishing a cancelled login.
                try Task.checkCancellation()
                try move(staged[index], files[index].path)
                published.insert(index)
            }
        } catch {
            // Do not check cancellation during rollback: the explicit-login
            // signal wrapper waits for this task before permitting exit.
            // Restore metadata before the old token. If restoration itself
            // fails, surface that error and retain the remaining original files.
            for index in files.indices {
                if backedUp.contains(index) {
                    try move(backups[index], files[index].path)
                } else if published.contains(index) {
                    try manager.removeItem(at: files[index].path)
                }
            }
            throw error
        }
        for index in backedUp { try? manager.removeItem(at: backups[index]) }
    }
}

private struct ProviderCredentialRecoveryFile: Sendable, Equatable {
    let path: URL
    let data: Data?

    init(path: URL) throws {
        self.path = path
        do {
            data = try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            data = nil
        }
    }

    var value: String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private func credentialRecoveryRename(_ source: URL, _ destination: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
