import Foundation
import Testing

@testable import ProviderCore

@Suite("signed release identity")
struct SignedReleaseIdentityTests {
    private let binaryHash = String(repeating: "a", count: 64)

    private func appLayout() -> (app: URL, executable: URL) {
        let app = URL(fileURLWithPath: "/private/tmp/Darkbloom.app", isDirectory: true)
        return (
            app,
            app.appendingPathComponent("Contents/MacOS/darkbloom"))
    }

    private func dependencies(
        processExecutable: URL? = nil,
        bundleExecutable: URL? = nil,
        app: URL? = nil,
        releaseBuild: Bool = true,
        version: String = "0.8.11",
        hash: String? = nil,
        signatureFailure: (any Error)? = nil
    ) -> SignedReleaseIdentity.Dependencies {
        let layout = appLayout()
        return .init(
            processExecutableURL: { processExecutable ?? layout.executable },
            bundleExecutableURL: { bundleExecutable ?? layout.executable },
            bundleURL: { app ?? layout.app },
            isReleaseBuild: { releaseBuild },
            providerVersion: { version },
            hashExecutable: { _ in hash ?? binaryHash },
            verifySignature: { _, _ in
                if let signatureFailure { throw signatureFailure }
            })
    }

    @Test("valid packaged main executable binds hash and version")
    func validIdentity() throws {
        let verified = try SignedReleaseIdentity.verify(
            expectedBinarySHA256: binaryHash,
            expectedVersion: "0.8.11",
            dependencies: dependencies())

        #expect(verified.identifier == "io.darkbloom.provider")
        #expect(verified.teamID == "SLDQ2GJ6TL")
        #expect(verified.executableName == "darkbloom")
        #expect(verified.executableSHA256 == binaryHash)
        #expect(verified.expectedExecutableSHA256 == binaryHash)
        #expect(verified.providerVersion == "0.8.11")
    }

    @Test("flat or non-main execution is rejected before signature claims")
    func rejectsInvalidLayout() {
        let flat = URL(fileURLWithPath: "/usr/local/bin/darkbloom")
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: binaryHash,
                expectedVersion: "0.8.11",
                dependencies: dependencies(
                    processExecutable: flat,
                    bundleExecutable: flat,
                    app: URL(fileURLWithPath: "/usr/local/bin")))
        }
    }

    @Test("expected hash and version must match exactly")
    func rejectsIdentityMismatch() {
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: String(repeating: "b", count: 64),
                expectedVersion: "0.8.11",
                dependencies: dependencies())
        }
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: binaryHash,
                expectedVersion: "0.8.10",
                dependencies: dependencies())
        }
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: binaryHash.uppercased(),
                expectedVersion: "0.8.11",
                dependencies: dependencies())
        }
    }

    @Test("signature failure cannot produce verified evidence")
    func rejectsSignatureFailure() {
        struct Failure: Error {}
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: binaryHash,
                expectedVersion: "0.8.11",
                dependencies: dependencies(signatureFailure: Failure()))
        }
    }

    @Test("deep app designated requirement seals the main executable")
    func verifiesDeepAppRequirement() throws {
        let layout = appLayout()
        let lock = NSLock()
        var calls: [String] = []
        let dependencies = SignedReleaseIdentity.Dependencies(
            processExecutableURL: { layout.executable },
            bundleExecutableURL: { layout.executable },
            bundleURL: { layout.app },
            isReleaseBuild: { true },
            providerVersion: { "0.8.11" },
            hashExecutable: { _ in binaryHash },
            verifySignature: { url, deep in
                lock.withLock {
                    calls.append("\(url.lastPathComponent):\(deep)")
                }
            })

        _ = try SignedReleaseIdentity.verify(
            expectedBinarySHA256: binaryHash,
            expectedVersion: "0.8.11",
            dependencies: dependencies)

        #expect(lock.withLock { calls } == ["Darkbloom.app:true"])
    }

    @Test("debug configuration cannot issue signed evidence")
    func rejectsDebugBuild() {
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verify(
                expectedBinarySHA256: binaryHash,
                expectedVersion: "0.8.11",
                dependencies: dependencies(releaseBuild: false))
        }
    }

    @Test("public verifier rejects the current debug test executable")
    func publicVerifierRejectsDebugExecutable() {
        #if DEBUG
        #expect(throws: SignedReleaseIdentity.VerificationError.self) {
            _ = try SignedReleaseIdentity.verifyCurrent(
                expectedBinarySHA256: binaryHash,
                expectedVersion: ProviderCore.version)
        }
        #endif
    }
}
