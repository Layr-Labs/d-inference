import Foundation
import Testing
@testable import ProviderCore

/// Live-event seam of `performDeviceCodeLogin` (RFC 8628 device flow) against
/// the Hummingbird `MockCoordinator`: `darkbloom login --json` serializes
/// `DeviceLoginEvent` as NDJSON for the macOS app's onboarding, so the
/// emission contract — code once, exactly one terminal event, no hang on
/// expiry/denial — is pinned end-to-end here.
///
/// `.serialized` + env indirection: the flow consults the real
/// `AuthTokenStore` (via `DARKBLOOM_AUTH_TOKEN_PATH`), so every test points
/// it at a throwaway directory and restores the environment afterwards.
@Suite("Device login live events", .serialized)
struct DeviceLoginEventTests {
    private func withAuthTokenOverride<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await credentialEnvironmentTestLock.withLock {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "device-login-events-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let tokenPath = dir.appendingPathComponent("auth_token").path
            let accountPath = dir.appendingPathComponent("provider_account").path
            let issuerPath = dir.appendingPathComponent("provider_issuer").path
            let previousToken = ProcessInfo.processInfo.environment[
                "DARKBLOOM_AUTH_TOKEN_PATH"
            ]
            let previousAccount = ProcessInfo.processInfo.environment[
                "DARKBLOOM_PROVIDER_ACCOUNT_PATH"
            ]
            let previousIssuer = ProcessInfo.processInfo.environment[
                "DARKBLOOM_PROVIDER_ISSUER_PATH"
            ]
            setenv("DARKBLOOM_AUTH_TOKEN_PATH", tokenPath, 1)
            setenv("DARKBLOOM_PROVIDER_ACCOUNT_PATH", accountPath, 1)
            setenv("DARKBLOOM_PROVIDER_ISSUER_PATH", issuerPath, 1)
            defer {
                if let previousToken {
                    setenv("DARKBLOOM_AUTH_TOKEN_PATH", previousToken, 1)
                } else {
                    unsetenv("DARKBLOOM_AUTH_TOKEN_PATH")
                }
                if let previousAccount {
                    setenv("DARKBLOOM_PROVIDER_ACCOUNT_PATH", previousAccount, 1)
                } else {
                    unsetenv("DARKBLOOM_PROVIDER_ACCOUNT_PATH")
                }
                if let previousIssuer {
                    setenv("DARKBLOOM_PROVIDER_ISSUER_PATH", previousIssuer, 1)
                } else {
                    unsetenv("DARKBLOOM_PROVIDER_ISSUER_PATH")
                }
                try? FileManager.default.removeItem(at: dir)
            }
            return try await body(URL(fileURLWithPath: tokenPath))
        }
    }

    final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DeviceLoginEvent] = []

        var events: [DeviceLoginEvent] {
            lock.withLock { storage }
        }

        func record(_ event: DeviceLoginEvent) {
            lock.withLock { storage.append(event) }
        }
    }

    @Test("Approval emits .code once then a terminal .linked, and saves the token")
    func loginEmitsCodeThenLinked() async throws {
        try await withAuthTokenOverride { tokenPath in
            let mock = MockCoordinator(
                deviceCode: MockDeviceCodeFixture(
                    userCode: "TEST-CODE",
                    verificationURI: "https://example.test/activate",
                    token: "mock-token-123"
                )
            )
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }

            let recorder = EventRecorder()
            let token = try await performDeviceCodeLogin(
                coordinatorURL: base.absoluteString,
                onDisplayCode: { _, _, _ in },
                openBrowser: false,
                onEvent: { recorder.record($0) }
            )

            #expect(token == "mock-token-123")
            #expect(recorder.events == [
                .code(userCode: "TEST-CODE", verificationURI: "https://example.test/activate", expiresIn: 300),
                .linked,
            ])
            #expect(recorder.events.last?.isTerminal == true)
            #expect(try String(contentsOf: tokenPath) == "mock-token-123")
            #expect(ProviderAccountStore.load() == "mock-account-id")
            let expectedIssuer = try canonicalCoordinatorIssuer(base.absoluteString)
            #expect(ProviderIssuerStore.load() == expectedIssuer)
        }
    }

    @Test("A non-2xx poll response is terminal and preserves its HTTP detail")
    func pollHTTPStatusIsHandled() async throws {
        try await withAuthTokenOverride { tokenPath in
            let mock = MockCoordinator(
                deviceCode: MockDeviceCodeFixture(
                    denialMessage: "session is not authorized",
                    denialUsesUnauthorizedHTTPStatus: true
                )
            )
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }

            do {
                _ = try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false
                )
                Issue.record("expected the HTTP refusal to terminate login")
            } catch let error as DeviceAuthError {
                guard case .authorizationFailed(let detail) = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
                #expect(detail.contains("HTTP 401"))
                #expect(detail.contains("session is not authorized"))
            }
            #expect(!FileManager.default.fileExists(atPath: tokenPath.path))
            #expect(ProviderAccountStore.load() == nil)
            #expect(ProviderIssuerStore.load() == nil)
        }
    }

    @Test("Authorization without an account id publishes no partial credential")
    func missingAccountIdentityFailsAtomically() async throws {
        try await withAuthTokenOverride { tokenPath in
            let mock = MockCoordinator(
                deviceCode: MockDeviceCodeFixture(accountID: nil)
            )
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }

            await #expect(throws: DeviceAuthError.self) {
                _ = try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false
                )
            }
            #expect(!FileManager.default.fileExists(atPath: tokenPath.path))
            #expect(ProviderAccountStore.load() == nil)
            #expect(ProviderIssuerStore.load() == nil)
        }
    }

    @Test("Expiry terminates the poll loop with an .error event, not a hang")
    func loginEmitsErrorOnExpiry() async throws {
        try await withAuthTokenOverride { _ in
            // Never authorizes; the 1s expiry must force a deterministic halt.
            let mock = MockCoordinator(
                deviceCode: MockDeviceCodeFixture(
                    expiresIn: 1,
                    interval: 1,
                    authorizeImmediately: false
                )
            )
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }

            let recorder = EventRecorder()
            let started = ContinuousClock.now
            do {
                _ = try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { recorder.record($0) }
                )
                Issue.record("expected the flow to throw on expiry")
            } catch let error as DeviceAuthError {
                guard case .deviceCodeExpired = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
            }

            // Bounded runtime proves the "no hang" contract of the poll loop.
            #expect(ContinuousClock.now - started < .seconds(10))
            guard recorder.events.count == 2,
                  case .code = recorder.events[0],
                  case .error(let message) = recorder.events[1]
            else {
                Issue.record("unexpected events: \(recorder.events)")
                return
            }
            #expect(message.contains("expired"))
        }
    }

    @Test("Coordinator refusal ends the attempt with a terminal .error event")
    func loginEmitsErrorOnDenial() async throws {
        try await withAuthTokenOverride { _ in
            let mock = MockCoordinator(
                deviceCode: MockDeviceCodeFixture(denialMessage: "user declined the link")
            )
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }

            let recorder = EventRecorder()
            do {
                _ = try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { recorder.record($0) }
                )
                Issue.record("expected the flow to throw on denial")
            } catch let error as DeviceAuthError {
                guard case .authorizationFailed(let detail) = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
                #expect(detail == "user declined the link")
            }

            guard recorder.events.count == 2,
                  case .code = recorder.events[0],
                  case .error(let message) = recorder.events[1]
            else {
                Issue.record("unexpected events: \(recorder.events)")
                return
            }
            #expect(message.contains("user declined the link"))
        }
    }

    @Test("An existing login short-circuits with an .error event before any network call")
    func loginEmitsErrorWhenAlreadyLoggedIn() async throws {
        try await withAuthTokenOverride { _ in
            try ProviderCredentialStore.save(
                token: "existing-token-with-20-plus-characters",
                accountID: "existing-account",
                coordinatorURL: "http://127.0.0.1:1"
            )

            let recorder = EventRecorder()
            do {
                // No mock coordinator: the flow must fail before touching the
                // network, and the URL is unreachable-on-purpose.
                _ = try await performDeviceCodeLogin(
                    coordinatorURL: "http://127.0.0.1:1",
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { recorder.record($0) }
                )
                Issue.record("expected the flow to throw when already logged in")
            } catch let error as DeviceAuthError {
                guard case .alreadyLoggedIn = error else {
                    Issue.record("wrong error: \(error)")
                    return
                }
            }

            #expect(recorder.events.count == 1)
            guard case .error(let message) = recorder.events.first else {
                Issue.record("unexpected events: \(recorder.events)")
                return
            }
            #expect(message.hasPrefix("Already logged in"))
            #expect(recorder.events.first?.isTerminal == true)
        }
    }

    @Test("A legacy credential fails with an actionable local recovery command")
    func legacyCredentialEmitsRecoveryGuidance() async throws {
        try await withAuthTokenOverride { _ in
            try AuthTokenStore.save("legacy-token-without-issuer")

            let recorder = EventRecorder()
            await #expect(throws: DeviceAuthError.credentialRecoveryRequired) {
                _ = try await performDeviceCodeLogin(
                    coordinatorURL: "http://127.0.0.1:1",
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { recorder.record($0) }
                )
            }

            guard case .error(let message) = recorder.events.first else {
                Issue.record("unexpected events: \(recorder.events)")
                return
            }
            #expect(message.contains("logout --local-only"))
            #expect(recorder.events.count == 1)
        }
    }
}
