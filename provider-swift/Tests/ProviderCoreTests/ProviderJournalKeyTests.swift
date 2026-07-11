import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

@Test
func providerJournalKeyIsStableAcrossInstancesAndConcurrentFirstUse() async throws {
    let service = "io.darkbloom.provider.journal-key-test.\(UUID().uuidString)"
    let installationAccount = "install-\(UUID().uuidString.lowercased())"
    let cleanup = ProviderJournalKey(
        service: service,
        installationAccount: installationAccount
    )

    do {
        try cleanup.deleteKey()
    } catch ProviderJournalKeyError.missingEntitlement {
        print("Skipping journal Keychain test: missing keychain entitlement")
        return
    }
    defer { try? cleanup.deleteKey() }

    let keys: [Data]
    do {
        keys = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let source = ProviderJournalKey(
                        service: service,
                        installationAccount: installationAccount
                    )
                    let key = try source.loadOrCreateKey()
                    return key.withUnsafeBytes { Data($0) }
                }
            }
            var values: [Data] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
    } catch ProviderJournalKeyError.missingEntitlement {
        print("Skipping journal Keychain test: missing keychain entitlement")
        return
    }

    let first = try #require(keys.first)
    #expect(first.count == 32)
    #expect(
        keys.allSatisfy { $0 == first },
        "SecItemAdd create-if-absent must make concurrent instances adopt one key")

    let reopened = try ProviderJournalKey(
        service: service,
        installationAccount: installationAccount
    )
    .loadOrCreateKey()
    .withUnsafeBytes { Data($0) }
    #expect(reopened == first)
}

@Test
func providerJournalKeyRejectsInvalidInstallationAccount() {
    #expect(throws: ProviderJournalKeyError.self) {
        _ = try ProviderJournalKey(
            service: "io.darkbloom.provider.journal-key-invalid.\(UUID().uuidString)",
            installationAccount: ""
        ).loadOrCreateKey()
    }
    #expect(throws: ProviderJournalKeyError.self) {
        _ = try ProviderJournalKey(
            service: "io.darkbloom.provider.journal-key-invalid.\(UUID().uuidString)",
            installationAccount: String(repeating: "x", count: 257)
        ).loadOrCreateKey()
    }
}
