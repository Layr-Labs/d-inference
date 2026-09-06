import Foundation
@testable import ProviderCore

/// Synthetic bytes only: these fixtures exercise layout/hash policy with an
/// injected signature verifier, never run or install a provider process.
struct NestedProviderFixture {
    let root: URL
    let source: URL
    let installRoot: URL
    let app: URL
    let helper: URL
    let binary: URL
    let alias: URL
    let version: String

    init(version: String = "0.8.11", nested: Bool = true) throws {
        self.version = version
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nested-provider-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        installRoot = root.appendingPathComponent("install")
        app = source.appendingPathComponent("Darkbloom.app")
        helper = app.appendingPathComponent(ProviderAppLayout.helperRelativePath)
        alias = app.appendingPathComponent(ProviderAppLayout.aliasRelativePath)
        binary = nested ? app.appendingPathComponent(ProviderAppLayout.nestedBinaryRelativePath) : alias
        try UpdateRecoveryFixture.writeApp(version: version, root: source)
        if nested { try Self.nest(app: app, version: version) }
        let bin = source.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try FileManager.default.copyItem(
                at: binary.deletingLastPathComponent().appendingPathComponent(name),
                to: bin.appendingPathComponent(name))
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func archive() throws -> (url: URL, release: ReleaseInfo) {
        let archive = root.appendingPathComponent("release-\(UUID().uuidString).tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["czf", archive.path, "-C", source.path, "."]
        process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return (archive, ReleaseInfo(
            version: version, platform: "macos-arm64", url: "file://unused",
            bundleHash: try UpdateAtomicFilesystem.sha256(file: archive),
            binaryHash: try UpdateAtomicFilesystem.sha256(file: source.appendingPathComponent("bin/darkbloom")),
            metallibHash: try UpdateAtomicFilesystem.sha256(file: source.appendingPathComponent("bin/mlx.metallib"))))
    }

    func updater() -> SelfUpdater {
        SelfUpdater(
            coordinatorBaseURL: "http://localhost", installRoot: installRoot,
            verifyCodeSignatures: false, currentVersion: version, now: { 100 })
    }

    static func nest(app: URL, version: String) throws {
        let fm = FileManager.default
        let helper = app.appendingPathComponent(ProviderAppLayout.helperRelativePath)
        let nestedBin = helper.appendingPathComponent("Contents/MacOS")
        let outerBin = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: nestedBin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.copyItem(at: outerBin.appendingPathComponent(name), to: nestedBin.appendingPathComponent(name))
        }
        try Data("GUI-only-not-the-provider-hash".utf8).write(to: outerBin.appendingPathComponent("DarkbloomApp"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outerBin.appendingPathComponent("DarkbloomApp").path)
        try fm.copyItem(at: app.appendingPathComponent("Contents/Info.plist"), to: helper.appendingPathComponent("Contents/Info.plist"))
        try editInfo(app: app, key: "CFBundleExecutable", value: "DarkbloomApp")
        for bundle in [app, helper] {
            try Data("same-test-profile".utf8).write(to: bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
            let resource = bundle.appendingPathComponent("Contents/Resources/TestRuntime.bundle/resource.txt")
            try fm.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("real runtime resource".utf8).write(to: resource)
        }
        let alias = outerBin.appendingPathComponent("darkbloom")
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: ProviderAppLayout.aliasTarget)
    }

    static func editInfo(app: URL, key: String, value: String) throws {
        let url = app.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
        info[key] = value
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
    }
}
