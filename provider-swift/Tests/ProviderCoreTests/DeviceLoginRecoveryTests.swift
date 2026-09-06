import Foundation
import Testing
@testable import ProviderCore

extension DeviceLoginEventTests {
    @Test("Explicit login freshly authorizes incomplete credentials and publishes a bound login",
          arguments: ["none", "account", "issuer"])
    func explicitLegacyRecoverySucceeds(metadata: String) async throws {
        try await withAuthTokenOverride { tokenPath in
            let mock = MockCoordinator(deviceCode: MockDeviceCodeFixture(token: "fresh-token", accountID: "fresh-account"))
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }
            try AuthTokenStore.save(" legacy-token\n")
            if metadata == "account" { try ProviderAccountStore.save(" original-account\n") }
            if metadata == "issuer" { try ProviderIssuerStore.save(base.absoluteString) }
            let original = try RecoveryOriginalFiles()
            let recorder = EventRecorder()

            let token = try await performDeviceCodeLogin(
                coordinatorURL: base.absoluteString,
                onDisplayCode: { _, _, _ in },
                openBrowser: false,
                onEvent: { event in
                    recorder.record(event)
                    if case .code = event {
                        #expect((try? RecoveryOriginalFiles()) == original)
                        #expect(throws: ProviderCredentialStoreError.incompleteCredential) {
                            try ProviderCredentialStore.authenticationToken(for: base.absoluteString)
                        }
                    }
                },
                recoverIncompleteCredential: true
            )

            #expect(token == "fresh-token")
            #expect(recorder.events == [
                .code(userCode: "MOCK-1234", verificationURI: "https://example.test/link", expiresIn: 300),
                .linked,
            ])
            #expect(try ProviderCredentialStore.load(for: base.absoluteString) == ProviderCredential(
                token: "fresh-token", accountID: "fresh-account", issuer: base.absoluteString
            ))
            #expect(throws: ProviderCredentialStoreError.issuerMismatch(
                expected: "https://other.example", actual: base.absoluteString
            )) {
                try ProviderCredentialStore.authenticationToken(for: "https://other.example")
            }
            for path in [tokenPath, ProviderAccountStore.accountPath(), ProviderIssuerStore.issuerPath()] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                #expect(attributes[.posixPermissions] as? Int == 0o600)
            }
        }
    }

    @Test("Denial, expiry, and missing authorized identity preserve incomplete credentials",
          arguments: ["denied", "expired", "missing-account"])
    func failedLegacyRecoveryPreservesOriginal(failure: String) async throws {
        try await withAuthTokenOverride { _ in
            let mock = MockCoordinator(deviceCode: MockDeviceCodeFixture(
                expiresIn: failure == "expired" ? 0 : 300,
                accountID: failure == "missing-account" ? nil : "fresh-account",
                denialMessage: failure == "denied" ? "user declined" : nil
            ))
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }
            try AuthTokenStore.save(" legacy-token\n")
            try ProviderAccountStore.save(" original-account\n")
            try ProviderIssuerStore.save(" \n")
            let original = try RecoveryOriginalFiles()
            let recorder = EventRecorder()

            do {
                try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { recorder.record($0) },
                    recoverIncompleteCredential: true
                )
                Issue.record("expected unsuccessful authorization")
            } catch let error as DeviceAuthError {
                switch (failure, error) {
                case ("denied", .authorizationFailed("user declined")),
                     ("expired", .deviceCodeExpired),
                     ("missing-account", .invalidResponse("authorized but no account identity in response")):
                    break
                default:
                    Issue.record("unexpected failure: \(error)")
                }
            }
            #expect(try RecoveryOriginalFiles() == original)
            #expect(recorder.events.count == 2)
            #expect(recorder.events.filter(\.isTerminal).count == 1)
            guard case .error = recorder.events.last else {
                Issue.record("unsuccessful recovery must end with an error event")
                return
            }
        }
    }

    @Test("Cancelling explicit recovery while waiting for authorization preserves every original file")
    func cancelledLegacyRecoveryPreservesOriginal() async throws {
        try await withAuthTokenOverride { _ in
            let mock = MockCoordinator(deviceCode: MockDeviceCodeFixture(authorizeImmediately: false))
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }
            try AuthTokenStore.save(" legacy-token\n")
            try ProviderAccountStore.save(" original-account\n")
            let original = try RecoveryOriginalFiles()
            let recorder = EventRecorder()
            let attempt = Task {
                try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { event in
                        recorder.record(event)
                        if case .code = event { withUnsafeCurrentTask { $0?.cancel() } }
                    },
                    recoverIncompleteCredential: true
                )
            }
            do {
                _ = try await attempt.value
                Issue.record("cancelled recovery must fail")
            } catch is CancellationError {}

            #expect(try RecoveryOriginalFiles() == original)
            #expect(recorder.events.count == 2)
            #expect(recorder.events.filter(\.isTerminal).count == 1)
            guard case .error = recorder.events.last else {
                Issue.record("cancellation must end with an error event")
                return
            }
        }
    }

    @Test("Fresh authorization cannot overwrite a login replaced while the device code was pending")
    func legacyRecoveryPreservesConcurrentLogin() async throws {
        try await withAuthTokenOverride { _ in
            let mock = MockCoordinator(deviceCode: MockDeviceCodeFixture(token: "late-token"))
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }
            try AuthTokenStore.save("legacy-token")
            let recorder = EventRecorder()
            let newer = ProviderCredential(token: "newer-token", accountID: "newer-account", issuer: "https://newer.example")

            do {
                try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { event in
                        recorder.record(event)
                        guard case .code = event else { return }
                        do {
                            try ProviderCredentialStore.deleteLocalCredential()
                            try ProviderCredentialStore.save(
                                token: newer.token, accountID: newer.accountID, coordinatorURL: newer.issuer
                            )
                        } catch { Issue.record("could not simulate concurrent login: \(error)") }
                    },
                    recoverIncompleteCredential: true
                )
                Issue.record("late authorization must not replace the newer login")
            } catch ProviderCredentialStoreError.credentialChanged {}

            #expect(try ProviderCredentialStore.load() == newer)
            #expect(recorder.events.count == 2)
            #expect(!recorder.events.contains(.linked))
            guard case .error(let message) = recorder.events.last else {
                Issue.record("concurrent replacement must end with an error event")
                return
            }
            #expect(message.contains("changed"))
        }
    }

    @Test("Explicit recovery refuses a known different issuer before requesting a device code")
    func legacyRecoveryRefusesDifferentIssuer() async throws {
        try await withAuthTokenOverride { _ in
            try AuthTokenStore.save("legacy-token")
            try ProviderIssuerStore.save("https://original.example")
            let original = try RecoveryOriginalFiles()
            let recorder = EventRecorder()
            do {
                try await performDeviceCodeLogin(
                    coordinatorURL: "http://127.0.0.1:1",
                    onDisplayCode: { _, _, _ in Issue.record("must not request a device code") },
                    openBrowser: false,
                    onEvent: { recorder.record($0) },
                    recoverIncompleteCredential: true
                )
                Issue.record("expected issuer mismatch")
            } catch let error as DeviceAuthError {
                guard case .invalidResponse(let detail) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(detail.contains("https://original.example"))
            }
            #expect(try RecoveryOriginalFiles() == original)
            #expect(recorder.events.count == 1)
            #expect(recorder.events.first?.isTerminal == true)
        }
    }
}
