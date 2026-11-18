import Foundation
import Testing
@testable import ProviderCore

/// A provider signed with a certificate refuses, before it starts them, cluster helpers that are not signed with
/// its own leaf certificate and their identifier, and an owner that is not its own image; it checks the owners it
/// did not verify. An Apple-signed executable (a private copy of `/bin/sleep`, whose signature is embedded) stands
/// in for the signed provider and its genuine helper; the same copy re-signed ad hoc under the same identifier
/// stands in for a helper signed otherwise. The checks on a running child are in ClusterInstalledSessionChecks.
@Suite("Cluster helpers signed like the provider", .serialized)
struct DistributedInstalledHelperSignatureTests {
    struct Bench {
        let root: URL, genuine: URL, adHoc: URL
        let provider: DistributedInstalledHelperSignature, signer: DistributedInstalledHelperSignature.Signer
        var helper: DistributedInstalledHelper { .init(identifier: signer.identifier) }

        init() throws {
            // The verifier opens every component without following links: use the real path (/var is a link).
            guard let real = realpath(NSTemporaryDirectory(), nil) else { throw POSIXError(.ENOENT) }
            defer { free(real) }
            root = URL(fileURLWithPath: String(cString: real)).appendingPathComponent("helper-signature-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            genuine = root.appendingPathComponent("genuine-helper")
            adHoc = root.appendingPathComponent("ad-hoc-helper")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: genuine)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: adHoc)
            guard case .signed(let signer) = DistributedInstalledHelperSignature.file(genuine) else {
                throw POSIXError(.ENOEXEC)
            }
            self.signer = signer
            provider = .signed(signer)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", signer.identifier, adHoc.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            guard sign.terminationStatus == 0, DistributedInstalledHelperSignature.file(adHoc) == .unsigned else {
                throw POSIXError(.ENOEXEC)
            }
        }

        func verified(_ file: URL) throws -> DistributedInstalledFiles.Identity {
            try DistributedInstalledFiles.verify(file, expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: file)),
                maximumBytes: 256 << 20, executable: true, deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
        }

        func signed(leaf: Data? = nil, cdhash: Data? = nil) -> DistributedInstalledHelperSignature {
            .signed(.init(leafSHA1: leaf ?? signer.leafSHA1, identifier: signer.identifier,
                          cdhash: cdhash ?? signer.cdhash, team: signer.team))
        }
    }

    @Test func aHelperSignedAdHocWithAnotherCertificateOrUnderAnotherIdentifierIsRefusedBeforeItStarts() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        // Pinned by its own bytes, as a setup without a coordinator approval pins it.
        #expect(throws: (any Error).self) { _ = try bench.verified(bench.adHoc).launchVerifier(bench.helper, signature: bench.provider) }
        #expect(throws: (any Error).self) {
            _ = try bench.verified(bench.genuine).launchVerifier(bench.helper, signature: bench.signed(leaf: Data(repeating: 0x5a, count: 20)))
        }
        #expect(throws: (any Error).self) { _ = try bench.verified(bench.genuine).launchVerifier(.worker, signature: bench.provider) }
        // The genuine helper passes the check before its spawn.
        _ = try bench.verified(bench.genuine).launchVerifier(bench.helper, signature: bench.provider)
    }

    @Test func aSignedProviderChecksEveryOwnerAndOnlyItsOwnImagePasses() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        // The owners no launcher verified before (a session's local rank, the link follower) are checked too.
        #expect(try bench.provider.ownerVerifier(bench.genuine) != nil)
        #expect(throws: (any Error).self) { _ = try bench.provider.ownerVerifier(bench.adHoc) }
        #expect(throws: (any Error).self) { _ = try bench.verified(bench.adHoc).launchVerifier(.owner, signature: bench.provider) }
        // The same certificate and identifier, but not the provider's own image.
        let otherImage = bench.signed(cdhash: Data(repeating: 0x11, count: 20))
        #expect(throws: (any Error).self) { _ = try otherImage.ownerVerifier(bench.genuine) }
        #expect(throws: (any Error).self) { _ = try bench.verified(bench.genuine).launchVerifier(.owner, signature: otherImage) }
        _ = try bench.verified(bench.genuine).launchVerifier(.owner, signature: bench.provider)
    }

    @Test func doctorNamesWhatTheLaunchWouldRefuse() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let worker = bench.provider.doctor(owner: bench.genuine, worker: bench.genuine)
        #expect(worker.passed == false)
        #expect(worker.detail.contains("io.darkbloom.darkbloom-cluster-worker"))
        #expect(!worker.detail.contains("not this Darkbloom's own signed executable"))
        let both = bench.provider.doctor(owner: bench.adHoc, worker: bench.adHoc)
        #expect(both.passed == false)
        #expect(both.detail.contains("not this Darkbloom's own signed executable"))
        #expect(DistributedInstalledHelperSignature.unsigned.doctor(owner: bench.adHoc, worker: bench.adHoc).passed == nil)
        #expect(DistributedInstalledHelperSignature.unavailable.doctor(owner: bench.genuine, worker: bench.genuine).passed == false)
    }

    @Test func aBuildWithoutTheCertificateKeepsThePinnedCheckAndOneThatCannotReadItRefuses() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        #expect(try DistributedInstalledHelperSignature.unsigned.ownerVerifier(bench.adHoc) == nil)
        _ = try bench.verified(bench.adHoc).launchVerifier(.worker, signature: .unsigned)
        #expect(throws: (any Error).self) { _ = try DistributedInstalledHelperSignature.unavailable.ownerVerifier(bench.genuine) }
        #expect(throws: (any Error).self) { _ = try bench.verified(bench.genuine).launchVerifier(.worker, signature: .unavailable) }
    }
}
