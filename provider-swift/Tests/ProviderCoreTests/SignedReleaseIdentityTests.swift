import Foundation
import Testing
@testable import ProviderCore

@Suite("signed release identity")
struct SignedReleaseIdentityTests {
    private func dependencies(
        _ fixture: NestedProviderFixture,
        nested: Bool = true,
        processExecutable: URL? = nil,
        bundleExecutable: URL? = nil,
        bundle: URL? = nil,
        releaseBuild: Bool = true,
        version: String? = nil,
        verifySignature: @escaping (URL, Bool) throws -> Void = { _, _ in }
    ) -> SignedReleaseIdentity.Dependencies {
        .init(
            processExecutableURL: { processExecutable ?? fixture.binary },
            bundleExecutableURL: { bundleExecutable ?? fixture.binary },
            bundleURL: { bundle ?? (nested ? fixture.helper : fixture.app) },
            isReleaseBuild: { releaseBuild },
            providerVersion: { version ?? fixture.version },
            hashExecutable: { try? UpdateAtomicFilesystem.sha256(file: $0) },
            verifySignature: verifySignature)
    }

    @Test("nested and legacy signed evidence binds the actual CLI hash and version")
    func validIdentity() throws {
        for nested in [false, true] {
            let fixture = try NestedProviderFixture(nested: nested)
            defer { fixture.cleanup() }
            let hash = try UpdateAtomicFilesystem.sha256(file: fixture.binary)
            var calls: [String] = []
            let verified = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: hash, expectedVersion: fixture.version,
                dependencies: dependencies(fixture, nested: nested, verifySignature: { url, deep in
                    calls.append("\(url.lastPathComponent):\(deep)")
                }))
            #expect(verified.identifier == "io.darkbloom.provider")
            #expect(verified.teamID == "SLDQ2GJ6TL")
            #expect(verified.executableName == "darkbloom")
            #expect(verified.executableSHA256 == hash)
            #expect(verified.expectedExecutableSHA256 == hash)
            #expect(verified.providerVersion == fixture.version)
            #expect(calls == (nested ? ["DarkbloomProvider.app:true", "Darkbloom.app:true"] : ["Darkbloom.app:true"]))
        }
    }

    @Test("alias invocation accepts only the exact helper or outer main-bundle context")
    func aliasInvocation() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let hash = try UpdateAtomicFilesystem.sha256(file: fixture.binary)
        for outerContext in [false, true] {
            let verified = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: hash, expectedVersion: fixture.version,
                dependencies: dependencies(
                    fixture, processExecutable: fixture.alias,
                    bundleExecutable: outerContext ? fixture.app.appendingPathComponent("Contents/MacOS/DarkbloomApp") : fixture.binary,
                    bundle: outerContext ? fixture.app : fixture.helper))
            #expect(verified.executableSHA256 == hash)
        }
        let guiHash = try UpdateAtomicFilesystem.sha256(file: fixture.app.appendingPathComponent("Contents/MacOS/DarkbloomApp"))
        #expect(hash != guiHash)
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: guiHash, expectedVersion: fixture.version,
                dependencies: dependencies(fixture))
        }
    }

    @Test("flat, GUI, arbitrary nested bundle, and non-main execution cannot issue evidence")
    func rejectsInvalidLayout() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let hash = try UpdateAtomicFilesystem.sha256(file: fixture.binary)
        for executable in [
            fixture.source.appendingPathComponent("bin/darkbloom"),
            fixture.app.appendingPathComponent("Contents/MacOS/DarkbloomApp"),
            fixture.app.appendingPathComponent("Contents/Helpers/Other.app/Contents/MacOS/darkbloom"),
        ] {
            #expect(throws: SignedReleaseIdentity.VerificationError.self) {
                _ = try SignedReleaseIdentity.verify(
                    expectedBinarySHA256: hash, expectedVersion: fixture.version,
                    dependencies: dependencies(fixture, processExecutable: executable))
            }
        }
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: hash, expectedVersion: fixture.version,
                dependencies: dependencies(fixture, bundleExecutable: fixture.alias, bundle: fixture.app))
        }
    }

    @Test("expected hash, runtime version, and metadata versions must all agree")
    func rejectsIdentityMismatch() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let hash = try UpdateAtomicFilesystem.sha256(file: fixture.binary)
        for expectedHash in [String(repeating: "a", count: 64), hash.uppercased(), "bad"] {
            #expect(throws: SignedReleaseIdentity.VerificationError.self) {
                _ = try SignedReleaseIdentity.verify(
                    expectedBinarySHA256: expectedHash, expectedVersion: fixture.version,
                    dependencies: dependencies(fixture))
            }
        }
        for expectedVersion in ["0.8.10", "", " 0.8.11", "0.8.11\n"] {
            #expect(throws: SignedReleaseIdentity.VerificationError.self) {
                _ = try SignedReleaseIdentity.verify(
                    expectedBinarySHA256: hash, expectedVersion: expectedVersion,
                    dependencies: dependencies(fixture))
            }
        }
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: hash, expectedVersion: fixture.version,
                dependencies: dependencies(fixture, version: "0.8.10"))
        }
    }

    @Test("either bundle signature failure prevents verified evidence")
    func rejectsSignatureFailure() throws {
        struct Failure: Error {}
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let hash = try UpdateAtomicFilesystem.sha256(file: fixture.binary)
        for target in [fixture.app, fixture.helper] {
            #expect(throws: SignedReleaseIdentity.VerificationError.self) {
                _ = try SignedReleaseIdentity.verify(
                    expectedBinarySHA256: hash, expectedVersion: fixture.version,
                    dependencies: dependencies(fixture, verifySignature: { url, _ in
                        if url.path == target.path { throw Failure() }
                    }))
            }
        }
    }

    @Test("correct binary bytes cannot excuse a tampered alias or metadata")
    func rejectsTamperedPackaging() throws {
        for mutateAlias in [false, true] {
            let fixture = try NestedProviderFixture()
            defer { fixture.cleanup() }
            let hash = try UpdateAtomicFilesystem.sha256(file: fixture.binary)
            if mutateAlias {
                try FileManager.default.removeItem(at: fixture.alias)
                try FileManager.default.createSymbolicLink(at: fixture.alias, withDestinationURL: fixture.binary)
            } else {
                try NestedProviderFixture.editInfo(app: fixture.app, key: "CFBundleIdentifier", value: "other.identity")
            }
            #expect(throws: SignedReleaseIdentity.VerificationError.self) {
                _ = try SignedReleaseIdentity.verify(
                    expectedBinarySHA256: hash, expectedVersion: fixture.version,
                    dependencies: dependencies(fixture))
            }
        }
    }

    @Test("debug configuration cannot issue signed evidence")
    func rejectsDebugBuild() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: String(repeating: "a", count: 64), expectedVersion: fixture.version,
                dependencies: dependencies(fixture, releaseBuild: false))
        }
    }

    @Test("public verifier rejects the current debug test executable")
    func publicVerifierRejectsDebugExecutable() {
        #if DEBUG
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verifyCurrent(
                expectedBinarySHA256: String(repeating: "a", count: 64), expectedVersion: ProviderCore.version)
        }
        #endif
    }
}
