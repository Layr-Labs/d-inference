import Foundation
import Testing
@testable import ProviderCore

/// A provider signed with a certificate reads what a cluster helper prints (the worker's runtime description, the
/// placement tool's answers) only from a helper signed with its own leaf certificate under that helper's
/// identifier: the file is checked before the spawn, and the suspended child before it runs. An Apple-signed
/// executable stands in for the signed provider and its genuine helper: a private copy of `/bin/echo` is the file
/// that is checked, and `/bin/echo` itself, the same bytes, is the child that runs (macOS runs Apple's executables
/// only from their system paths). The same copy re-signed ad hoc under the same identifier stands in for a helper
/// signed otherwise. Because the checked child runs from the system path, whose file the installed-file rules refuse
/// (another user owns it), the genuine run goes through the `verifyLaunched:` form with the check made on the copy;
/// `ZZLocalSignedArtifactProof` (evidence only) ran the `helper:` form end to end on a signed DevNet app.
@Suite("Cluster helpers' metadata launches signed like the provider", .serialized)
struct DistributedInstalledMetadataHelperSignatureTests {
    static let system = URL(fileURLWithPath: "/bin/echo")

    struct Bench {
        let root: URL, genuine: URL, adHoc: URL
        let provider: DistributedInstalledHelperSignature, signer: DistributedInstalledHelperSignature.Signer
        var helper: DistributedInstalledHelper { .init(identifier: signer.identifier) }

        init() throws {
            // The verifier opens every component without following links: use the real path (/var is a link).
            guard let real = realpath(NSTemporaryDirectory(), nil) else { throw POSIXError(.ENOENT) }
            defer { free(real) }
            root = URL(fileURLWithPath: String(cString: real)).appendingPathComponent("metadata-helper-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            genuine = root.appendingPathComponent("genuine-helper")
            adHoc = root.appendingPathComponent("ad-hoc-helper")
            try FileManager.default.copyItem(at: system, to: genuine)
            try FileManager.default.copyItem(at: system, to: adHoc)
            guard case .signed(let signer) = DistributedInstalledHelperSignature.file(genuine) else { throw POSIXError(.ENOEXEC) }
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

        func run(_ executable: URL, _ words: [String], helper: DistributedInstalledHelper?,
                 signature: DistributedInstalledHelperSignature) throws -> Data {
            try DistributedCapabilityProbe.run(executable: executable, arguments: words,
                deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000_000, maximumOutputBytes: 4096,
                helper: helper, signature: signature)
        }

        func run(_ executable: URL, _ words: [String], verifyLaunched: (@Sendable (pid_t) throws -> Void)?) throws -> Data {
            try DistributedCapabilityProbe.run(executable: executable, arguments: words,
                deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000_000, maximumOutputBytes: 4096,
                verifyLaunched: verifyLaunched)
        }

        func signed(leaf: Data) -> DistributedInstalledHelperSignature {
            .signed(.init(leafSHA1: leaf, identifier: signer.identifier, cdhash: signer.cdhash, team: signer.team))
        }
    }

    private func refusal(_ body: () throws -> Data) -> String {
        do { _ = try body(); return "" } catch { return "\(error)" }
    }

    @Test func aHelperSignedAdHocIsRefusedBeforeAnythingItPrintsIsRead() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        // A build without the certificate starts it and reads it, as before.
        #expect(try bench.run(bench.adHoc, ["described"], helper: bench.helper, signature: .unsigned) == Data("described\n".utf8))
        let message = refusal { try bench.run(bench.adHoc, ["described"], helper: bench.helper, signature: bench.provider) }
        #expect(message.contains("is not signed by the same Developer ID"))
    }

    @Test func aHelperWithAnotherCertificateOrUnderAnotherIdentifierIsRefusedBeforeItStarts() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let otherCertificate = bench.signed(leaf: Data(repeating: 0x5a, count: 20))
        #expect(refusal { try bench.run(bench.genuine, ["x"], helper: bench.helper, signature: otherCertificate) }
            .contains("is not signed by the same Developer ID"))
        #expect(refusal { try bench.run(bench.genuine, ["x"], helper: .planner, signature: bench.provider) }
            .contains("io.darkbloom.darkbloom-cluster-plan is not signed by the same Developer ID"))
        #expect(refusal { try bench.run(bench.genuine, ["x"], helper: .worker, signature: bench.provider) }
            .contains("io.darkbloom.darkbloom-cluster-worker is not signed by the same Developer ID"))
        // One that cannot read its own signature starts no helper.
        #expect(refusal { try bench.run(bench.genuine, ["x"], helper: bench.helper, signature: .unavailable) }
            .contains("could not read its own code signature"))
    }

    @Test func aHelperSwappedAfterItsCheckIsRefusedBeforeItRuns() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let path = bench.root.appendingPathComponent(DistributedInstalledHelper.plannerName)
        try FileManager.default.copyItem(at: bench.genuine, to: path)
        let check = try bench.provider.metadataVerifier(bench.helper, file: path, deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000_000)
        #expect(check != nil)
        let staged = bench.root.appendingPathComponent("staged")
        try FileManager.default.copyItem(at: bench.adHoc, to: staged)
        #expect(rename(staged.path, path.path) == 0)
        #expect(refusal { try bench.run(path, ["swapped"], verifyLaunched: check) }
            .contains("The launched executable is not the verified installed one"))
    }

    @Test func theGenuineHelperIsCheckedWhileSuspendedThenRunsAndIsRead() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let check = try #require(try bench.provider.metadataVerifier(bench.helper, file: bench.genuine,
            deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000_000))
        #expect(try bench.run(Self.system, ["described"], verifyLaunched: check) == Data("described\n".utf8))
    }

    @Test func doctorNamesThePlacementToolSignedOtherwise() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let result = bench.provider.doctor(owner: bench.genuine, worker: bench.genuine, planner: bench.adHoc)
        #expect(result.passed == false)
        #expect(result.detail.contains("io.darkbloom.darkbloom-cluster-plan"))
        #expect(DistributedInstalledHelperSignature.unsigned.doctor(owner: bench.adHoc, worker: bench.adHoc, planner: bench.adHoc).passed == nil)
    }

    @Test func thePlannerNameIsThePlacementTool() {
        #expect(DistributedInstalledHelper.plannerName == ClusterRuntimeApprovalFacts.Installation.placementToolName)
    }

    /// `touch` stands in for a helper here: a run leaves its file behind.
    struct Toucher {
        let root: URL, adHoc: URL, provider: DistributedInstalledHelperSignature
        let helper = DistributedInstalledHelper(identifier: "com.apple.touch")
        init(_ bench: Bench) throws {
            root = bench.root
            let genuine = root.appendingPathComponent("genuine-touch")
            adHoc = root.appendingPathComponent("ad-hoc-touch")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/touch"), to: genuine)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/touch"), to: adHoc)
            guard case .signed(let signer) = DistributedInstalledHelperSignature.file(genuine) else { throw POSIXError(.ENOEXEC) }
            provider = .signed(signer)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--identifier", signer.identifier, adHoc.path]
            sign.standardOutput = FileHandle.nullDevice; sign.standardError = FileHandle.nullDevice
            try sign.run(); sign.waitUntilExit()
            guard sign.terminationStatus == 0 else { throw POSIXError(.ENOEXEC) }
        }
    }

    @Test func theSetupWizardDoesNotStartARefusedHelperAgainForItsErrorLine() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let toucher = try Toucher(bench)
        // Unchecked (a build without the certificate) the helper runs: its file appears.
        let ran = bench.root.appendingPathComponent("ran-unchecked")
        _ = LiveContext.toolErrorLine(executable: toucher.adHoc, arguments: [ran.path], helper: toucher.helper, signature: .unsigned)
        #expect(FileManager.default.fileExists(atPath: ran.path))
        // A signed provider whose check refuses the helper does not start it to read its error line.
        let refused = bench.root.appendingPathComponent("ran-refused")
        #expect(LiveContext.toolErrorLine(executable: toucher.adHoc, arguments: [refused.path], helper: toucher.helper,
                                          signature: toucher.provider) == nil)
        #expect(!FileManager.default.fileExists(atPath: refused.path))
    }

    @Test func aStagedModelCopyIsDescribedOnlyByAWorkerSignedLikeTheProvider() throws {
        let bench = try Bench(); defer { try? FileManager.default.removeItem(at: bench.root) }
        let toucher = try Toucher(bench)
        let artifact = ClusterCatalogArtifact(modelID: "fixture/model", version: "1", aggregateSHA256: String(repeating: "a", count: 64),
                                              totalBytes: 0, files: [], manifest: Data(), r2Prefix: nil)
        let check = ClusterModelWorkerCheck(executable: toucher.adHoc, runtimeBinarySHA256: String(repeating: "b", count: 64),
                                            signature: toucher.provider)
        let refusal = try #require(check.refusal(staged: bench.root, artifact: artifact))
        #expect(refusal.contains("is not signed by the same Developer ID"))
    }
}
