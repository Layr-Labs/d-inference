import Foundation
import Testing
@testable import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

@Suite("Provider credential publication", .serialized)
struct ProviderCredentialStoreTests {
    @Test("credential use is bound to the issuing coordinator")
    func issuerBinding() async throws {
        try await withCredentialFiles { _ in
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

            try ProviderCredentialStore.deleteLocalCredential()
            let cleared = try ProviderCredentialStore.load()
            #expect(cleared == nil)
            #expect(!FileManager.default.fileExists(atPath: files.token.path))
        }
    }

    @Test("concurrent login attempts publish exactly one coherent credential")
    func concurrentPublication() async throws {
        try await withCredentialFiles { _ in
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
            let loaded = try ProviderCredentialStore.load()
            let stored = try #require(loaded)
            #expect(candidates.contains(stored))
        }
    }

    #if canImport(Darwin)
    @Test("credential publication waits for a lock owned by another process")
    func crossProcessSerialization() async throws {
        try await withCredentialFiles { files in
            let lockPath = files.directory.appendingPathComponent(
                ".provider-credential.lock"
            )
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = [
                "-e",
                """
                use Fcntl qw(:flock);
                $| = 1;
                open(my $fh, '>>', $ARGV[0]) or die $!;
                flock($fh, LOCK_EX) or die $!;
                print '1';
                sleep 30;
                """,
                lockPath.path,
            ]
            let output = Pipe()
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            try child.run()
            defer {
                if child.isRunning {
                    _ = kill(child.processIdentifier, SIGKILL)
                    child.waitUntilExit()
                }
            }
            let ready = output.fileHandleForReading.readData(ofLength: 1)
            try #require(ready == Data("1".utf8))

            let state = CredentialSaveState()
            let saveTask = Task.detached {
                await state.markStarted()
                do {
                    try ProviderCredentialStore.save(
                        token: "cross-process-token",
                        accountID: "cross-process-account",
                        coordinatorURL: "https://issuer.example"
                    )
                    await state.markCompleted()
                } catch {
                    await state.markCompleted()
                    throw error
                }
            }

            for _ in 0..<1_000 {
                if await state.started {
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let didStart = await state.started
            try #require(didStart)
            try await Task.sleep(for: .milliseconds(100))
            let completedWhileChildOwnedLock = await state.completed
            #expect(!completedWhileChildOwnedLock)

            _ = kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            try await saveTask.value
            let stored = try ProviderCredentialStore.load()
            #expect(stored?.token == "cross-process-token")
        }
    }
    #endif

    @Test("delayed logout cannot delete a newer credential")
    func compareAndDelete() async throws {
        try await withCredentialFiles { _ in
            try ProviderCredentialStore.save(
                token: "old-token",
                accountID: "old-account",
                coordinatorURL: "https://old.example"
            )
            let loaded = try ProviderCredentialStore.load()
            let old = try #require(loaded)

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
        _ body: @Sendable (CredentialFiles) async throws -> T
    ) async throws -> T {
        try await credentialEnvironmentTestLock.withLock {
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
}

private actor CredentialSaveState {
    private(set) var started = false
    private(set) var completed = false

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }
}
