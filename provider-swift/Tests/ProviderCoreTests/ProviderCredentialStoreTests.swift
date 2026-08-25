import Foundation
import Testing
@testable import ProviderCore

@Suite("Provider credential publication", .serialized)
struct ProviderCredentialStoreTests {
    @Test("credential use is bound to the issuing coordinator")
    func issuerBinding() async throws {
        try await withCredentialFiles {
            try ProviderCredentialStore.save(
                token: "token-a",
                accountID: "account-a",
                coordinatorURL: "wss://Issuer.Example/ws/provider"
            )

            let credential = try ProviderCredentialStore.load(
                for: "https://issuer.example/other/path"
            )
            #expect(credential == ProviderCredential(
                token: "token-a",
                accountID: "account-a",
                issuer: "https://issuer.example"
            ))
            #expect(throws: ProviderCredentialStoreError.issuerMismatch(
                expected: "https://other.example",
                actual: "https://issuer.example"
            )) {
                try ProviderCredentialStore.load(
                    for: "wss://other.example/ws/provider"
                )
            }
        }
    }

    @Test("a token without complete binding metadata fails closed")
    func incompleteCredential() async throws {
        try await withCredentialFiles { files in
            try "legacy-token".write(
                to: files.token,
                atomically: true,
                encoding: .utf8
            )

            #expect(throws: ProviderCredentialStoreError.incompleteCredential) {
                try ProviderCredentialStore.load(
                    for: "https://configured.example"
                )
            }
        }
    }

    @Test("concurrent login attempts publish exactly one coherent credential")
    func concurrentPublication() async throws {
        try await withCredentialFiles {
            let candidates = (0..<32).map { index in
                ProviderCredential(
                    token: "token-\(index)",
                    accountID: "account-\(index)",
                    issuer: "https://issuer-\(index).example"
                )
            }

            let successes = await withTaskGroup(
                of: Bool.self,
                returning: Int.self
            ) { group in
                for candidate in candidates {
                    group.addTask {
                        do {
                            try ProviderCredentialStore.save(
                                token: candidate.token,
                                accountID: candidate.accountID,
                                coordinatorURL: candidate.issuer
                            )
                            return true
                        } catch ProviderCredentialStoreError.alreadyLoggedIn {
                            return false
                        } catch {
                            Issue.record("unexpected save failure: \(error)")
                            return false
                        }
                    }
                }

                var count = 0
                for await succeeded in group where succeeded {
                    count += 1
                }
                return count
            }

            #expect(successes == 1)
            let stored = try #require(ProviderCredentialStore.load())
            #expect(candidates.contains(stored))
        }
    }

    @Test("delayed logout cannot delete a newer credential")
    func compareAndDelete() async throws {
        try await withCredentialFiles {
            try ProviderCredentialStore.save(
                token: "old-token",
                accountID: "old-account",
                coordinatorURL: "https://old.example"
            )
            let old = try #require(ProviderCredentialStore.load())

            try AuthTokenStore.save("new-token")
            try ProviderAccountStore.save("new-account")
            try ProviderIssuerStore.save("https://new.example")

            #expect(throws: ProviderCredentialStoreError.credentialChanged) {
                try ProviderCredentialStore.delete(matching: old)
            }
            let current = try ProviderCredentialStore.load()
            #expect(current == ProviderCredential(
                token: "new-token",
                accountID: "new-account",
                issuer: "https://new.example"
            ))
        }
    }

    private struct CredentialFiles {
        let directory: URL
        let token: URL
    }

    private func withCredentialFiles<T: Sendable>(
        _ body: (CredentialFiles) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-credential-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let files = CredentialFiles(
            directory: directory,
            token: directory.appendingPathComponent("auth_token")
        )
        let overrides = [
            "DARKBLOOM_AUTH_TOKEN_PATH": files.token.path,
            "DARKBLOOM_PROVIDER_ACCOUNT_PATH": directory
                .appendingPathComponent("provider_account").path,
            "DARKBLOOM_PROVIDER_ISSUER_PATH": directory
                .appendingPathComponent("provider_issuer").path,
        ]
        let previous: [String: String?] = Dictionary(
            uniqueKeysWithValues: overrides.keys.map {
                ($0, ProcessInfo.processInfo.environment[$0])
            }
        )
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        return try await body(files)
    }
}
