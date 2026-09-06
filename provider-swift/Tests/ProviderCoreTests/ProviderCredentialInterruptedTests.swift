import Foundation
import Testing
@testable import ProviderCore

extension ProviderCredentialStoreTests {
    @Test("Only matching canonical-token UUID originals fence legacy fallback",
          arguments: ["matching", "different-token", "invalid-uuid", "pending-only"])
    func interruptedArtifactMatching(kind: String) async throws {
        try await withCredentialFiles { files in
            let id = UUID().uuidString
            let names = [
                "matching": "auth_token.\(id).original",
                "different-token": "other_token.\(id).original",
                "invalid-uuid": "auth_token.not-a-uuid.original",
                "pending-only": "auth_token.\(id).pending",
            ]
            let artifact = files.directory.appendingPathComponent(try #require(names[kind]))
            try Data("backup-token-must-not-load".utf8).write(to: artifact)
            let legacy = files.directory.appendingPathComponent("legacy-token")
            try Data("retained-legacy-token".utf8).write(to: legacy)
            let token = AuthTokenStore.load(canonicalPath: files.token, legacyPaths: [legacy])
            if kind == "matching" {
                #expect(token == nil)
                #expect(!FileManager.default.fileExists(atPath: files.token.path))
                #expect(throws: ProviderCredentialStoreError.credentialRecoveryRequired) {
                    try ProviderCredentialStore.load(for: "https://fresh.example")
                }
            } else {
                #expect(token == "retained-legacy-token")
            }
            #expect(try String(contentsOf: artifact, encoding: .utf8) == "backup-token-must-not-load")
        }
    }

    @Test("Failed transaction inspection cannot import or return a legacy token")
    func interruptedInspectionFailsClosed() async throws {
        try await withCredentialFiles { files in
            let legacy = files.directory.appendingPathComponent("legacy-token")
            try Data("retained-legacy-token".utf8).write(to: legacy)
            // Create the sidecar before making the directory searchable but
            // unreadable. Known-file reads remain possible; enumeration fails.
            #expect(try ProviderCredentialStore.load() == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: files.directory.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path)
            }
            #expect(AuthTokenStore.load(canonicalPath: files.token, legacyPaths: [legacy]) == nil)
            #expect(throws: ProviderCredentialStoreError.credentialRecoveryRequired) {
                try ProviderCredentialStore.authenticationToken(for: "https://fresh.example")
            }
            #expect(!FileManager.default.fileExists(atPath: files.token.path))
        }
    }

    @Test("Interrupted-state error is actionable and ordinary save cannot bypass it")
    func interruptedRecoveryRequiredError() async throws {
        try await withCredentialFiles { _ in
            _ = try seedInterruptedCredentialArtifacts()
            #expect(ProviderCredentialStoreError.credentialRecoveryRequired.localizedDescription
                == "the saved provider credential requires recovery; run `darkbloom login` to authorize a fresh login")
            #expect(throws: ProviderCredentialStoreError.credentialRecoveryRequired) {
                try ProviderCredentialStore.save(
                    token: "new-token", accountID: "new-account", coordinatorURL: "https://fresh.example"
                )
            }
            #expect(AuthTokenStore.load() == nil)
        }
    }

    @Test("Interrupted recovery compares artifact identity before publishing",
          arguments: ["replace", "add", "remove"])
    func interruptedRecoveryComparesArtifacts(change: String) async throws {
        try await withCredentialFiles { _ in
            let artifacts = try seedInterruptedCredentialArtifacts()
            let original = try RecoveryOriginalFiles()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(for: "https://fresh.example"))
            switch change {
            case "replace":
                try Data("replaced-backup".utf8).write(to: artifacts[0], options: .atomic)
            case "add":
                try Data("another-transaction".utf8).write(
                    to: ProviderAccountStore.accountPath().appendingPathExtension("\(UUID().uuidString).original")
                )
            default:
                try FileManager.default.removeItem(at: artifacts[0])
            }
            #expect(throws: ProviderCredentialStoreError.credentialChanged) {
                try recovery.publish(token: "fresh-token", accountID: "fresh-account")
            }
            #expect(try RecoveryOriginalFiles() == original)
        }
    }

    @Test("A failed fresh publication retains interrupted artifacts for another explicit attempt")
    func interruptedRecoveryFailurePreservesArtifacts() async throws {
        try await withCredentialFiles { _ in
            _ = try seedInterruptedCredentialArtifacts()
            let original = try RecoveryOriginalFiles()
            let artifacts = try captureCredentialArtifacts()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(for: "https://fresh.example"))
            #expect(throws: InterruptedPublicationFailure.injected) {
                try recovery.publish(token: "fresh-token", accountID: "fresh-account") { _, _ in
                    throw InterruptedPublicationFailure.injected
                }
            }
            #expect(try RecoveryOriginalFiles() == original)
            #expect(try captureCredentialArtifacts() == artifacts)
        }
    }

    @Test("Explicit fresh publication cleans captured artifacts from multiple interrupted generations")
    func interruptedRecoveryCleansCapturedGenerations() async throws {
        try await withCredentialFiles { _ in
            _ = try seedInterruptedCredentialArtifacts()
            let otherID = UUID().uuidString
            let extra = ProviderAccountStore.accountPath().appendingPathExtension("\(otherID).original")
            try Data("older-metadata".utf8).write(to: extra)
            let recovery = try #require(try ProviderCredentialRecovery.prepare(for: "https://fresh.example"))
            try recovery.publish(token: "fresh-token", accountID: "fresh-account")
            #expect(try captureCredentialArtifacts().isEmpty)
            #expect(try ProviderCredentialStore.load(for: "https://fresh.example") == ProviderCredential(
                token: "fresh-token", accountID: "fresh-account", issuer: "https://fresh.example"
            ))
        }
    }
}

func captureCredentialArtifacts() throws -> [ProviderCredentialRecoveryArtifacts.Snapshot] {
    try ProviderCredentialRecoveryArtifacts.capture(credentialPaths: [
        AuthTokenStore.tokenPath(), ProviderAccountStore.accountPath(), ProviderIssuerStore.issuerPath(),
    ])
}

private func seedInterruptedCredentialArtifacts() throws -> [URL] {
    try ProviderAccountStore.save("interrupted-account")
    try ProviderIssuerStore.save("https://fresh.example")
    let id = UUID().uuidString
    let backup = AuthTokenStore.tokenPath().appendingPathExtension("\(id).original")
    let pending = AuthTokenStore.tokenPath().appendingPathExtension("\(id).pending")
    try Data("backup-token-must-not-load".utf8).write(to: backup)
    try Data("interrupted-token-must-not-load".utf8).write(to: pending)
    return [backup, pending]
}

private enum InterruptedPublicationFailure: Error, Equatable { case injected }
