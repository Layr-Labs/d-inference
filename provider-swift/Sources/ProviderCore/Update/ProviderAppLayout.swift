import Foundation
import ProviderCoreFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resolves only the two published app layouts. Callers hash and open the real
/// payload paths; the one compatibility alias never enters generic nofollow IO.
struct ProviderAppLayout {
    static let helperRelativePath = ManagedProviderInstallLayout.helperAppRelativePath
    static let aliasRelativePath = ManagedProviderInstallLayout.legacyCLIRelativePath
    static let aliasTarget = ManagedProviderInstallLayout.compatibilityCLISymlinkTarget
    static let nestedMacOSRelativePath = helperRelativePath + "/Contents/MacOS"
    static let nestedBinaryRelativePath = ManagedProviderInstallLayout.cliRelativePath

    let app: URL
    let helper: URL?
    let binary: URL
    let enclave: URL
    let metallib: URL
    var runtimeBundle: URL { helper ?? app }

    init(app: URL, expectedVersion: String? = nil) throws {
        self.app = app.standardizedFileURL
        guard self.app.lastPathComponent == ManagedProviderInstallLayout.appBundleName else {
            throw Self.invalid("provider layout requires the outer Darkbloom.app")
        }
        try Self.requireDirectory(self.app)
        try Self.requireDirectory(self.app.appendingPathComponent("Contents"))
        let outerBin = self.app.appendingPathComponent("Contents/MacOS")
        try Self.requireDirectory(outerBin)
        let alias = self.app.appendingPathComponent(Self.aliasRelativePath)
        let nested = self.app.appendingPathComponent(Self.helperRelativePath)
        let isNested = UpdateAtomicFilesystem.itemExists(nested)
            || Self.isSymlink(alias)
        if isNested {
            helper = nested
            try Self.requireDirectory(self.app.appendingPathComponent("Contents/Helpers"))
            try Self.requireDirectory(nested)
            try Self.requireDirectory(nested.appendingPathComponent("Contents"))
            try Self.requireDirectory(nested.appendingPathComponent("Contents/MacOS"))
            guard Self.isSymlink(alias),
                  try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
                    == Self.aliasTarget
            else {
                throw Self.invalid("nested provider requires the exact outer CLI alias")
            }
            binary = nested.appendingPathComponent("Contents/MacOS/darkbloom")
            enclave = nested.appendingPathComponent("Contents/MacOS/darkbloom-enclave")
            metallib = nested.appendingPathComponent("Contents/MacOS/mlx.metallib")
            try Self.validateNestedMetadata(
                outer: Self.readRegularData(self.app.appendingPathComponent("Contents/Info.plist")),
                helper: Self.readRegularData(nested.appendingPathComponent("Contents/Info.plist")),
                expectedVersion: expectedVersion)
            let outerProfile = try Self.readRegularData(
                self.app.appendingPathComponent("Contents/embedded.provisionprofile"))
            let helperProfile = try Self.readRegularData(
                nested.appendingPathComponent("Contents/embedded.provisionprofile"))
            guard !outerProfile.isEmpty, outerProfile == helperProfile else {
                throw Self.invalid("outer and nested provider provisioning profiles differ")
            }
            let retainedModes = try UpdateArtifactModes(
                binary: outerBin.appendingPathComponent("DarkbloomApp"),
                enclave: outerBin.appendingPathComponent("darkbloom-enclave"),
                metallib: outerBin.appendingPathComponent("mlx.metallib"))
            if let mismatch = retainedModes.releaseModeMismatch {
                throw Self.invalid(mismatch)
            }
            _ = try UpdateArtifactModes(binary: binary, enclave: enclave, metallib: metallib)
            for name in ["darkbloom-enclave", "mlx.metallib"] {
                guard try UpdateAtomicFilesystem.sha256(file: nested.appendingPathComponent("Contents/MacOS/" + name))
                    == UpdateAtomicFilesystem.sha256(file: outerBin.appendingPathComponent(name))
                else { throw Self.invalid("outer and nested provider \(name) copies differ") }
            }
            // SwiftPM resources and runtime capability markers must be real
            // colocated files, never aliases into a different bundle.
            try Self.requireResourceTree(self.app.appendingPathComponent("Contents/Resources"))
            try Self.requireResourceTree(nested.appendingPathComponent("Contents/Resources"))
        } else {
            helper = nil
            binary = alias
            enclave = outerBin.appendingPathComponent("darkbloom-enclave")
            metallib = outerBin.appendingPathComponent("mlx.metallib")
        }
        _ = try UpdateArtifactModes(binary: binary, enclave: enclave, metallib: metallib)
    }

    /// Evidence additionally binds metadata for the legacy CLI-main app.
    func validateIdentityMetadata(expectedVersion: String? = nil) throws {
        if helper == nil {
            _ = try Self.metadata(
                Self.readRegularData(app.appendingPathComponent("Contents/Info.plist")),
                executable: "darkbloom", expectedVersion: expectedVersion)
        }
    }

    static func validateNestedMetadata(
        outer: Data, helper: Data, expectedVersion: String? = nil
    ) throws {
        let version = try metadata(outer, executable: "DarkbloomApp", expectedVersion: expectedVersion)
        _ = try metadata(helper, executable: "darkbloom", expectedVersion: version)
    }

    private static func metadata(
        _ data: Data, executable: String, expectedVersion: String?
    ) throws -> String {
        guard let info = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == DarkbloomCodeSignature.bundleIdentifier,
            info["CFBundleExecutable"] as? String == executable,
            info["CFBundlePackageType"] as? String == "APPL",
            let version = info["CFBundleShortVersionString"] as? String,
            !version.isEmpty,
            version == version.trimmingCharacters(in: .whitespacesAndNewlines),
            !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            info["CFBundleVersion"] as? String == version,
            expectedVersion == nil || version == expectedVersion
        else {
            throw invalid("provider bundle identity, executable or version metadata is invalid")
        }
        return version
    }

    private static func requireResourceTree(_ directory: URL) throws {
        try requireDirectory(directory)
        for item in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            var status = stat()
            guard lstat(item.path, &status) == 0 else {
                throw invalid("cannot inspect provider resource \(item.path)")
            }
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR): try requireResourceTree(item)
            case mode_t(S_IFREG): break
            default: throw invalid("provider resources must be regular files and directories")
            }
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { throw invalid("provider bundle parent must be a real directory: \(url.path)") }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func readRegularData(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw invalid("cannot open provider metadata: \(url.path)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0, status.st_size <= 1024 * 1024
        else { throw invalid("provider metadata must be a bounded regular file: \(url.path)") }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw invalid("provider metadata exceeds its size limit") }
        return data
    }

    private static func invalid(_ detail: String) -> UpdateError {
        .replaceFailed(detail)
    }
}
