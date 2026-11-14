import Foundation
import Darwin
import Security
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote
@testable import InstalledContract

extension InstalledSessionCheck {
    /// The cdhash read from an executable's bytes is the one Code Signing
    /// Services reports for it, whatever the read sizes; a file without a
    /// usable signature has none and cannot be launched as verified.
    static func codeDirectoryFromVerifiedBytes(_ f: InstalledFixture) throws {
        func parsed(_ data: Data, chunk: Int = 64 << 10) -> Set<Data> {
            var reader = DistributedInstalledCodeDirectory(fileSize: data.count)
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + chunk)
                reader.update(data.subdata(in: offset..<end)); offset = end
            }
            return reader.finish()
        }
        func reported(_ url: URL) throws -> Data {
            var code: SecStaticCode?, information: CFDictionary?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
                  let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
                throw CheckFailure(message: "Code Signing Services reports no cdhash for \(url.lastPathComponent)")
            }
            return unique
        }
        // A universal system binary: the slice Code Signing Services picks is among the arm64 slices read.
        let ls = URL(fileURLWithPath: "/bin/ls"), universal = try Data(contentsOf: ls)
        try require(parsed(universal).contains(try reported(ls)) && parsed(universal, chunk: 7) == parsed(universal),
            "the cdhash read from /bin/ls differs from Code Signing Services'")
        // A thin binary this lane built (linker-signed).
        let thin = try Data(contentsOf: f.probe), expected = try reported(f.probe)
        try require(parsed(thin) == [expected] && parsed(thin, chunk: 13) == [expected],
            "the cdhash read from the probe differs from Code Signing Services'")

        let directory = f.root.appendingPathComponent("code-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func verified(_ name: String, _ bytes: Data) throws -> DistributedInstalledFiles.Identity {
            let file = directory.appendingPathComponent(name)
            try bytes.write(to: file); chmod(file.path, 0o700)
            return try DistributedInstalledFiles.verify(file, expectedSHA256: ClusterConfigurationCodec.sha256(bytes),
                maximumBytes: 256 << 20, executable: true, deadline: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        }
        let installed = try verified("probe", thin)
        try require(installed.codeDirectoryHashes == [expected], "installed verification did not keep the probe's cdhash")
        _ = try installed.launchVerifier()

        let stripped = directory.appendingPathComponent("stripped")
        try thin.write(to: stripped)
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--remove-signature", stripped.path]
        try codesign.run(); codesign.waitUntilExit()
        try require(codesign.terminationStatus == 0, "could not remove the probe's signature")
        let unsigned = try Data(contentsOf: stripped)
        try FileManager.default.removeItem(at: stripped)
        for (name, bytes) in [("truncated", thin.prefix(thin.count - 64)), ("unsigned", unsigned),
                              ("garbage", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37) })),
                              ("script", Data("#!/bin/sh\nexec /bin/cat\n".utf8))] {
            try require(parsed(bytes).isEmpty, "a \(name) executable has a cdhash")
            let identity = try verified(name, bytes)
            try require(identity.codeDirectoryHashes.isEmpty, "a \(name) installed executable kept a cdhash")
            try rejected { _ = try identity.launchVerifier() }
        }
    }

    /// The verified worker, and an owner that is the verified file, are
    /// launched and read their input; an owner replaced after its check is
    /// refused before its open frame (which carries the credential) is written.
    static func verifiedLaunchesAndReplacedOwner(_ f: InstalledFixture, recorder: URL) throws {
        let bench = try LaunchImageBench(f, name: "launch-image-owner")
        defer { bench.attachment.cancel() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000

        // The native launch carries the check, and the unchanged worker passes it (run here in a mode that
        // waits, so the check cannot race its exit).
        let launch = try DistributedInstalledOwner.nativeLaunch(prepared: bench.prepared, binding: bench.binding,
            deadline: bench.deadline, startupDeadline: nil, attachment: bench.attachment, dataPlaneTrust: bench.trust,
            prefixSSDKey: nil, ownerEnvironment: [:])
        let check = try require(launch.verifyLaunched, "the native launch carries no check of the launched image")
        let genuine = Process()
        genuine.executableURL = bench.worker; genuine.arguments = ["--fixture-hang"]
        try genuine.run()
        defer { kill(genuine.processIdentifier, SIGKILL); genuine.waitUntilExit() }
        try check(genuine.processIdentifier)

        // The recorder, verified as itself, is launched and reads the credential.
        let own = bench.directory.appendingPathComponent("recorder")
        try FileManager.default.copyItem(at: recorder, to: own)
        let identity = try DistributedInstalledFiles.verify(own, expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: own)),
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        let accepted = try ClusterWorkerProcess(launch: .init(executable: own, arguments: [], environment: [:],
                initialInput: bench.trust, verifyLaunched: identity.launchVerifier()),
            expectedIdentity: bench.binding.identity, rank: bench.binding.rank, profile: bench.binding.profile,
            executionPlanSHA256: bench.binding.executionPlanSHA256, startupDeadline: bench.deadline, initialLeaseDeadline: bench.deadline)
        try accepted.launch()
        try require(bench.received(accepted) == bench.trust, "the verified child did not receive its input")
        try FileManager.default.removeItem(at: bench.recorded)

        // The owner: verified, then replaced before the endpoint launches it.
        let owner = bench.directory.appendingPathComponent("darkbloom")
        try FileManager.default.copyItem(at: f.owner, to: owner)
        let ownerIdentity = try DistributedInstalledFiles.verify(owner,
            expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: owner)),
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        try bench.replace(owner, with: recorder)
        try rejected {
            _ = try ClusterRemoteWorkerEndpoint(localOwner: ClusterLocalOwnerConfiguration(installedDarkbloom: owner),
                clusterID: bench.prepared.plan.configuration.clusterID, expectedIdentity: bench.binding.identity,
                profile: bench.binding.profile, rank: bench.binding.rank, executionPlanSHA256: bench.binding.executionPlanSHA256,
                lifetimeDeadlineUptimeNanoseconds: deadline, bootstrapRelay: nil, dataPlaneTrust: bench.trust,
                verifyLaunched: ownerIdentity.launchVerifier())
        }
        Thread.sleep(forTimeInterval: 0.3)
        try require(!FileManager.default.fileExists(atPath: bench.recorded.path),
            "an owner binary replaced after verification received its open frame")
        print("Installed launch image: cdhashes from the verified bytes match Code Signing Services; unsigned, truncated and replaced worker and owner binaries refused before their input; verified children launched (CPU)")
    }
}
