import Foundation
import Testing
@testable import ProviderCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension ProviderCredentialSignalTests {
    @Test("SIGKILL after metadata publication fences legacy tokens until fresh authorization succeeds")
    func killedPublicationRequiresFreshAuthorization() async throws {
        guard ProcessInfo.processInfo.environment[credentialChildRootKey] == nil else { return }
        try await ProviderCredentialStoreTests().withCredentialFiles { files in
            let mock = MockCoordinator(deviceCode: MockDeviceCodeFixture(
                token: "reauthorized-token", accountID: "reauthorized-account"
            ))
            let base = try await mock.start()
            defer { Task { await mock.shutdown() } }
            try AuthTokenStore.save("original-token")
            let legacy = files.directory.appendingPathComponent("retained-legacy-token")
            try Data("retained-legacy-token\n".utf8).write(to: legacy)
            let child = try launchCredentialRecoveryChild(
                directory: files.directory, scenario: "sigkill-after-metadata", issuer: base.absoluteString
            )
            defer {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
            try await requireCredentialChildMarker("boundary.ready", in: files.directory, child: child)
            #expect(!FileManager.default.fileExists(atPath: files.token.path))
            #expect(ProviderAccountStore.load() == "fresh-account")
            #expect(ProviderIssuerStore.load() == base.absoluteString)
            #expect(kill(child.processIdentifier, SIGKILL) == 0)
            try await requireCredentialChildExit(child, in: files.directory, expectedSignal: SIGKILL)

            // The actual process was killed with fresh metadata on disk and
            // its token unpublished; neither catch nor defer cleaned it up.
            let artifacts = try captureCredentialArtifacts()
            #expect(artifacts.contains { $0.path.lastPathComponent.hasPrefix("auth_token.")
                && $0.path.pathExtension == "original" })
            let interruptedFiles = try RecoveryOriginalFiles()
            #expect(AuthTokenStore.load(canonicalPath: files.token, legacyPaths: [legacy]) == nil)
            #expect(AuthTokenStore.load() == nil)
            #expect(throws: ProviderCredentialStoreError.credentialRecoveryRequired) {
                try ProviderCredentialStore.authenticationToken(for: base.absoluteString)
            }
            #expect(try RecoveryOriginalFiles() == interruptedFiles)
            #expect(try captureCredentialArtifacts() == artifacts)
            #expect(!FileManager.default.fileExists(atPath: files.token.path))

            // A cancelled explicit authorization must leave the evidence intact
            // and must not turn either the backup or pending token into a login.
            let cancelledEvents = DeviceLoginEventTests.EventRecorder()
            let cancelled = Task {
                try await performDeviceCodeLogin(
                    coordinatorURL: base.absoluteString,
                    onDisplayCode: { _, _, _ in },
                    openBrowser: false,
                    onEvent: { event in
                        cancelledEvents.record(event)
                        if case .code = event {
                            #expect((try? captureCredentialArtifacts()) == artifacts)
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    },
                    recoverIncompleteCredential: true
                )
            }
            do {
                _ = try await cancelled.value
                Issue.record("cancelled reauthorization must not publish")
            } catch is CancellationError {}
            #expect(cancelledEvents.events.count == 2)
            #expect(!cancelledEvents.events.contains(.linked))
            #expect(try captureCredentialArtifacts() == artifacts)
            #expect(try RecoveryOriginalFiles() == interruptedFiles)

            let events = DeviceLoginEventTests.EventRecorder()
            let token = try await performDeviceCodeLogin(
                coordinatorURL: base.absoluteString,
                onDisplayCode: { _, _, _ in },
                openBrowser: false,
                onEvent: { event in
                    events.record(event)
                    if case .code = event {
                        #expect((try? captureCredentialArtifacts()) == artifacts)
                        #expect(AuthTokenStore.load(canonicalPath: files.token, legacyPaths: [legacy]) == nil)
                    }
                },
                recoverIncompleteCredential: true
            )
            #expect(token == "reauthorized-token")
            #expect(events.events == [
                .code(userCode: "MOCK-1234", verificationURI: "https://example.test/link", expiresIn: 300),
                .linked,
            ])
            #expect(try ProviderCredentialStore.load(for: base.absoluteString) == ProviderCredential(
                token: "reauthorized-token", accountID: "reauthorized-account", issuer: base.absoluteString
            ))
            #expect(AuthTokenStore.load(canonicalPath: files.token, legacyPaths: [legacy]) == "reauthorized-token")
            #expect(try captureCredentialArtifacts().isEmpty)
            #expect(try String(contentsOf: legacy, encoding: .utf8) == "retained-legacy-token\n")
        }
    }
}
