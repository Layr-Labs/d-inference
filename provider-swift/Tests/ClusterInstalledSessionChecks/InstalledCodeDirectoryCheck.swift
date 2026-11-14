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
}
