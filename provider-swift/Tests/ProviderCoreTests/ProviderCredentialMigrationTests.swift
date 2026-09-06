import Dispatch
import Foundation
import Testing
@testable import ProviderCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension ProviderCredentialSignalTests {
    @Test("A retained legacy token cannot migrate through another process's publication lock",
          arguments: [false, true])
    func concurrentMigrationWaitsForPublication(rollback: Bool) async throws {
        guard ProcessInfo.processInfo.environment[credentialChildRootKey] == nil else { return }
        try await ProviderCredentialStoreTests().withCredentialFiles { files in
            try AuthTokenStore.save("original-token")
            let legacy = files.directory.appendingPathComponent("retained-legacy-token")
            try Data("retained-legacy-token\n".utf8).write(to: legacy)
            let original = try RecoveryOriginalFiles()
            let recovery = try #require(try ProviderCredentialRecovery.prepare(for: "https://fresh.example"))
            let backedUp = DispatchSemaphore(value: 0)
            let allowPublication = DispatchSemaphore(value: 0)

            // Run the real publisher on a separate worker while a separate
            // process attempts the real canonical/legacy migration path. This
            // exercises flock, not just the in-process mutex or env overrides
            // (which intentionally disable default home-directory migration).
            let publication = Task {
                try await onCredentialWorker {
                    try recovery.publish(token: "fresh-token", accountID: "fresh-account") { source, destination in
                        if rollback && source.pathExtension == "pending" {
                            throw MigrationPublicationFailure.rollback
                        }
                        guard rename(source.path, destination.path) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                        if source.lastPathComponent == "auth_token", destination.pathExtension == "original" {
                            backedUp.signal()
                            _ = allowPublication.wait(timeout: .now() + 30)
                        }
                    }
                }
            }
            var child: Process?
            defer {
                if let child, child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
            do {
                let didBackUp = try await onCredentialWorker {
                    backedUp.wait(timeout: .now() + 30) == .success
                }
                try #require(didBackUp)
                let migrator = try launchCredentialRecoveryChild(directory: files.directory, scenario: "concurrent-migration")
                child = migrator
                try await requireCredentialChildMarker("migration.started", in: files.directory, child: migrator)
                // The child has started its read while the canonical token is
                // absent. It must stay blocked until the publisher releases the
                // same kernel lock and then re-read the final canonical token.
                try await Task.sleep(for: .milliseconds(150))
                #expect(migrator.isRunning)
                #expect(!FileManager.default.fileExists(atPath: files.token.path))
                #expect(!FileManager.default.fileExists(
                    atPath: files.directory.appendingPathComponent("migration.result").path
                ))
                allowPublication.signal()

                switch await publication.result {
                case .success:
                    #expect(!rollback)
                case .failure(let error):
                    #expect(rollback)
                    #expect(error as? MigrationPublicationFailure == .rollback)
                }
                try await requireCredentialChildExit(migrator, in: files.directory)
                let loaded = try String(
                    contentsOf: files.directory.appendingPathComponent("migration.result"), encoding: .utf8
                )
                #expect(loaded == (rollback ? "original-token" : "fresh-token"))
                #expect(try String(contentsOf: legacy, encoding: .utf8) == "retained-legacy-token\n")
                if rollback {
                    #expect(try RecoveryOriginalFiles() == original)
                } else {
                    #expect(try ProviderCredentialStore.load(for: "https://fresh.example") == ProviderCredential(
                        token: "fresh-token", accountID: "fresh-account", issuer: "https://fresh.example"
                    ))
                }
            } catch {
                // Join the worker before restoring the temporary-path env or
                // deleting its files, even if the subprocess cannot launch.
                allowPublication.signal()
                _ = await publication.result
                throw error
            }
        }
    }
}

private func onCredentialWorker<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try body() })
        }
    }
}

private enum MigrationPublicationFailure: Error, Equatable { case rollback }
