import Foundation
import Testing
@testable import ProviderCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension ProviderCredentialStoreTests {
    @Test("Recovery retains a recorded issuer guard when account metadata is missing")
    func recoveryRetainsIssuerBinding() async throws {
        try await withCredentialFiles { _ in
            try AuthTokenStore.save("legacy-token")
            try ProviderIssuerStore.save("https://original.example")
            #expect(throws: ProviderCredentialStoreError.issuerMismatch(
                expected: "https://other.example", actual: "https://original.example"
            )) {
                try ProviderCredentialRecovery.prepare(for: "https://other.example")
            }
            #expect(AuthTokenStore.load() == "legacy-token")
            #expect(ProviderIssuerStore.load() == "https://original.example")
            #expect(ProviderAccountStore.load() == nil)
        }
    }

    @Test("Recovery snapshots do not authorize overwriting complete credentials")
    func recoveryDoesNotReplaceCompleteLogin() async throws {
        try await withCredentialFiles { _ in
            try ProviderCredentialStore.save(
                token: "complete-token", accountID: "complete-account",
                coordinatorURL: "https://original.example"
            )
            #expect(try ProviderCredentialRecovery.prepare(for: "invalid URL") == nil)
            #expect(try ProviderCredentialStore.load()?.token == "complete-token")
        }
    }

    @Test("Recovery compares token and all metadata bytes, including absent files",
          arguments: ["token", "account", "issuer", "logout", "newer-login"])
    func recoveryRejectsConcurrentChange(change: String) async throws {
        try await withCredentialFiles { files in
            try AuthTokenStore.save("legacy-token")
            let recovery = try #require(try ProviderCredentialRecovery.prepare(
                for: "https://fresh.example"
            ))
            switch change {
            case "token":
                // Even a formatting-only change must invalidate the snapshot.
                try "legacy-token\n".write(to: files.token, atomically: true, encoding: .utf8)
            case "account":
                try ProviderAccountStore.save("concurrent-account")
            case "issuer":
                try ProviderIssuerStore.save("https://concurrent.example")
            case "logout":
                try ProviderCredentialStore.deleteLocalCredential()
            default:
                try ProviderCredentialStore.deleteLocalCredential()
                try ProviderCredentialStore.save(
                    token: "newer-token", accountID: "newer-account",
                    coordinatorURL: "https://newer.example"
                )
            }
            let current = try RecoveryOriginalFiles()
            #expect(throws: ProviderCredentialStoreError.credentialChanged) {
                try recovery.publish(token: "fresh-token", accountID: "fresh-account")
            }
            #expect(try RecoveryOriginalFiles() == current)
        }
    }

    @Test("Partial publication failures restore the exact original bytes and permissions",
          arguments: ["provider_account", "provider_issuer", "auth_token"], [false, true])
    func recoveryRollsBackPublication(failingFile: String, hasMetadata: Bool) async throws {
        try await withCredentialFiles { files in
            try AuthTokenStore.save(" legacy-token\n")
            if hasMetadata {
                try ProviderAccountStore.save(" original-account\n")
                try ProviderIssuerStore.save(" \n")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640], ofItemAtPath: files.token.path
            )
            let original = try RecoveryOriginalFiles()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(
                for: "https://fresh.example"
            ))
            #expect(throws: RecoveryPublicationFailure.injected) {
                try recovery.publish(token: "fresh-token", accountID: "fresh-account") { source, destination in
                    if source.pathExtension == "pending" {
                        // In particular, writing fresh binding records never
                        // leaves the legacy token published alongside them.
                        #expect(!FileManager.default.fileExists(atPath: files.token.path))
                        if destination.lastPathComponent == failingFile {
                            throw RecoveryPublicationFailure.injected
                        }
                    }
                    guard rename(source.path, destination.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
            #expect(try RecoveryOriginalFiles() == original)
            #expect(throws: ProviderCredentialStoreError.incompleteCredential) {
                try ProviderCredentialStore.load(for: "https://fresh.example")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
            #expect(!names.contains { $0.hasSuffix(".original") || $0.hasSuffix(".pending") })
        }
    }

    @Test("Invalid authorized credentials cannot replace the original", arguments: ["", " \n"])
    func recoveryRejectsEmptyAuthorizedFields(emptyValue: String) async throws {
        try await withCredentialFiles { _ in
            try AuthTokenStore.save("legacy-token")
            let original = try RecoveryOriginalFiles()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(
                for: "https://fresh.example"
            ))
            #expect(throws: ProviderCredentialStoreError.missingToken) {
                try recovery.publish(token: emptyValue, accountID: "fresh-account")
            }
            #expect(throws: ProviderCredentialStoreError.missingAccountID) {
                try recovery.publish(token: "fresh-token", accountID: emptyValue)
            }
            #expect(try RecoveryOriginalFiles() == original)
        }
    }

    @Test("Cancellation after authorization but before publication preserves the original")
    func recoveryCancelledBeforePublication() async throws {
        try await withCredentialFiles { _ in
            try AuthTokenStore.save(" legacy-token\n")
            try ProviderAccountStore.save(" legacy-account\n")
            let original = try RecoveryOriginalFiles()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(
                for: "https://fresh.example"
            ))
            let attempt = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try recovery.publish(token: "fresh-token", accountID: "fresh-account")
            }
            do {
                try await attempt.value
                Issue.record("cancelled recovery must not publish")
            } catch is CancellationError {}
            #expect(try RecoveryOriginalFiles() == original)
        }
    }
}

private enum RecoveryPublicationFailure: Error, Equatable { case injected }

/// Test-only byte/permission snapshots. Call only inside the shared temporary
/// credential environment lock; never falls back to a real home-directory file.
struct RecoveryOriginalFiles: Sendable, Equatable {
    private let contents: [Data?]
    private let permissions: [Int?]

    init() throws {
        let paths = [AuthTokenStore.tokenPath(), ProviderAccountStore.accountPath(), ProviderIssuerStore.issuerPath()]
        contents = try paths.map { path in
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try Data(contentsOf: path)
        }
        permissions = try paths.map { path in
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        }
    }
}
