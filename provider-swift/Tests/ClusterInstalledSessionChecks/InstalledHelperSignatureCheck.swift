import Foundation
import Darwin
import Security
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote
@testable import InstalledContract

/// A provider signed with a certificate starts a cluster helper only if the
/// helper is signed with the same leaf certificate and carries its identifier,
/// and its owner only if the owner is its own image. An Apple-signed executable
/// stands in for both the signed provider and its genuine helper: a private
/// copy of `/bin/sleep` (its signature is embedded) is the file a launcher
/// checks, and `/bin/sleep` itself runs as the child it checks (macOS runs
/// Apple's executables only from their system paths). The stdin recorder,
/// signed ad hoc with the same identifier, stands in for a helper signed otherwise.
extension InstalledSessionCheck {
    static func helperSignatureIsRequired(_ f: InstalledFixture, recorder: URL) throws {
        let bench = try LaunchImageBench(f, name: "helper-signature")
        defer { bench.attachment.cancel() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        func verified(_ file: URL) throws -> DistributedInstalledFiles.Identity {
            try DistributedInstalledFiles.verify(file, expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: file)),
                maximumBytes: 256 << 20, executable: true, deadline: deadline)
        }
        func worker(_ executable: URL, _ check: @escaping @Sendable (pid_t) throws -> Void) throws -> ClusterWorkerProcess {
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [], environment: [:],
                    initialInput: bench.trust, verifyLaunched: check),
                expectedIdentity: bench.binding.identity, rank: bench.binding.rank, profile: bench.binding.profile,
                executionPlanSHA256: bench.binding.executionPlanSHA256, startupDeadline: bench.deadline, initialLeaseDeadline: bench.deadline)
        }

        // The stand-in provider, running, and its genuine helper's file. Like `own()`, the provider's cdhash is the
        // kernel's for its running image.
        let genuine = bench.directory.appendingPathComponent("genuine-helper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: genuine)
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep"); running.arguments = ["30"]
        try running.run()
        defer { kill(running.processIdentifier, SIGKILL); running.waitUntilExit() }
        guard case .signed(let file) = DistributedInstalledHelperSignature.file(genuine),
              let image = DistributedInstalledLaunchImage.kernelHash(running.processIdentifier) else {
            throw CheckFailure(message: "the Apple-signed stand-in has no certificate or no running image")
        }
        let signer = DistributedInstalledHelperSignature.Signer(leafSHA1: file.leafSHA1, identifier: file.identifier,
                                                                cdhash: image, team: file.team)
        let provider = DistributedInstalledHelperSignature.signed(signer)
        let helper = DistributedInstalledHelper(identifier: signer.identifier)

        // A helper signed ad hoc with the right identifier, pinned by its own bytes (as a setup without a coordinator
        // approval pins it): refused before it is started, and it receives nothing.
        let adHoc = bench.directory.appendingPathComponent("ad-hoc-helper")
        try FileManager.default.copyItem(at: recorder, to: adHoc)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", signer.identifier, adHoc.path]
        try sign.run(); sign.waitUntilExit()
        try require(sign.terminationStatus == 0, "could not sign the stand-in helper ad hoc")
        var refused = false
        do {
            let child = try worker(adHoc, try verified(adHoc).launchVerifier(helper, signature: provider))
            try child.launch()
            _ = bench.received(child)
        } catch { refused = true }
        try require(!FileManager.default.fileExists(atPath: bench.recorded.path), "a helper signed ad hoc received the data-plane credential")
        try require(refused, "a helper signed ad hoc was started by a signed provider")

        // Control: the genuine helper and the provider's own image as its owner pass the check before the spawn and
        // the one on the running child.
        try verified(genuine).launchVerifier(helper, signature: provider)(running.processIdentifier)
        try verified(genuine).launchVerifier(.owner, signature: provider)(running.processIdentifier)
        let ownCheck = try require(try provider.ownerVerifier(genuine), "a signed provider launches its owner unchecked")
        try ownCheck(running.processIdentifier)

        // Signed with another certificate (a valid chain, the right identifier, another leaf), or with the right
        // certificate under another identifier: refused before the spawn.
        let other = DistributedInstalledHelperSignature.signed(.init(leafSHA1: Data(repeating: 0x5a, count: 20),
            identifier: signer.identifier, cdhash: signer.cdhash, team: signer.team))
        try rejected { _ = try verified(genuine).launchVerifier(helper, signature: other) }
        try rejected { _ = try other.ownerVerifier(genuine) }
        try rejected { _ = try verified(genuine).launchVerifier(.worker, signature: provider) }
        try rejected { _ = try verified(adHoc).launchVerifier(.owner, signature: provider) }
        try rejected { _ = try provider.ownerVerifier(adHoc) }
        // The owner is the provider's own image: the same certificate and identifier with another image is refused.
        let otherImage = DistributedInstalledHelperSignature.signed(.init(leafSHA1: signer.leafSHA1,
            identifier: signer.identifier, cdhash: Data(repeating: 0x11, count: 20), team: signer.team))
        try rejected { _ = try otherImage.ownerVerifier(genuine) }
        try rejected { _ = try verified(genuine).launchVerifier(.owner, signature: otherImage) }
        let otherOwner = otherImage.doctor(owner: genuine, worker: genuine)
        try require(otherOwner.passed == false && otherOwner.detail.contains("not this Darkbloom's own signed executable"),
            "doctor accepted an owner that is another image")

        // Swapped after the check before the spawn: the owner (whose file no one verified before) and the worker are
        // refused on their suspended child, before their first command.
        let ownerFile = bench.directory.appendingPathComponent("darkbloom")
        try FileManager.default.copyItem(at: genuine, to: ownerFile)
        let ownerCheck = try provider.ownerVerifier(ownerFile)
        try bench.replace(ownerFile, with: adHoc)
        refused = false
        do {
            _ = try ClusterRemoteWorkerEndpoint(localOwner: ClusterLocalOwnerConfiguration(installedDarkbloom: ownerFile),
                clusterID: bench.prepared.plan.configuration.clusterID, expectedIdentity: bench.binding.identity,
                profile: bench.binding.profile, rank: bench.binding.rank, executionPlanSHA256: bench.binding.executionPlanSHA256,
                lifetimeDeadlineUptimeNanoseconds: deadline, bootstrapRelay: nil, dataPlaneTrust: bench.trust,
                verifyLaunched: ownerCheck)
        } catch { refused = true }
        Thread.sleep(forTimeInterval: 0.3)
        try require(!FileManager.default.fileExists(atPath: bench.recorded.path),
            "an owner swapped after its signature check received its open frame")
        try require(refused, "an owner swapped after its signature check was started")

        let workerFile = bench.directory.appendingPathComponent("darkbloom-cluster-worker-signed")
        try FileManager.default.copyItem(at: genuine, to: workerFile)
        let workerCheck = try verified(workerFile).launchVerifier(helper, signature: provider)
        try bench.replace(workerFile, with: adHoc)
        let swapped = try worker(workerFile, workerCheck)
        refused = false
        do { try swapped.launch() } catch { refused = true }
        try require(bench.received(swapped) == nil, "a worker swapped after its signature check received the data-plane credential")
        try require(refused && swapped.termination == .launchFailed, "a worker swapped after its signature check was started")
        // The provider's own signature is usable only if it describes its running image (`own()`): one read from a
        // file that is not that image (replaced since the start) is not, so a release can't fall back to fewer checks.
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(genuine as CFURL, [], &code) == errSecSuccess, let code else {
            throw CheckFailure(message: "could not read the stand-in's signature")
        }
        try require(DistributedInstalledHelperSignature.of(code, cdhash: image, describing: Data(repeating: 0x11, count: 20)) == .unavailable,
            "a signature that does not describe the running image was used")
        try require(DistributedInstalledHelperSignature.of(code, cdhash: image) == provider, "the stand-in's signature changed")
        // A release uses its certificate only if it validly signs the running provider and is this project's team's:
        // the Apple-signed stand-in, running, does not pass as a release.
        var runningCode: SecCode?, ownRequirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: running.processIdentifier)] as CFDictionary,
                                             [], &runningCode) == errSecSuccess, let runningCode,
              SecRequirementCreateWithString(signer.ownRequirement(team: DistributedInstalledHelperSignature.releaseTeam) as CFString,
                                             [], &ownRequirement) == errSecSuccess, let ownRequirement else {
            throw CheckFailure(message: "could not read the running stand-in or parse the release requirement")
        }
        try require(SecCodeCheckValidity(runningCode, [], ownRequirement) != errSecSuccess, "another team's certificate passed as a release's")

        // `darkbloom cluster doctor` names what the launch would refuse.
        let doctor = provider.doctor(owner: genuine, worker: genuine)
        try require(doctor.passed == false && doctor.detail.contains("io.darkbloom.darkbloom-cluster-worker")
            && !doctor.detail.contains("not this Darkbloom's own signed executable"), "doctor did not name the worker signed otherwise alone")
        let both = provider.doctor(owner: adHoc, worker: adHoc)
        try require(both.passed == false && both.detail.contains("not this Darkbloom's own signed executable")
            && both.detail.contains("io.darkbloom.darkbloom-cluster-worker"),
            "doctor did not name an owner and a worker signed otherwise")
        try require(DistributedInstalledHelperSignature.unsigned.doctor(owner: adHoc, worker: adHoc).passed == nil,
            "doctor judged helpers in a build without a certificate")
        print("Installed helper signature: a helper signed ad hoc, with another certificate or under another identifier refused before it starts; owner and worker swapped after the check refused before their first command; the genuine helper passes both checks (CPU)")
    }
}
