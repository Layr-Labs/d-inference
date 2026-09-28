import Foundation
import Darwin
import Testing
@testable import ProviderCore

@Suite("Installed owner configuration reference")
struct ClusterInstalledReferenceTests {
    @Test("strict read preserves exact provider bytes and requires a saved pointer")
    func reference() throws {
        // Foundation can normalize /private/var back to the /var symlink.
        // Use the working directory for this deliberately link-free IO fixture.
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("installed-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        let expected = try ClusterConfigurationReference(configuration: "/Users/fixture/setup.cluster.json",
            sha256: String(repeating: "a", count: 64))
        let data = Data("# preserved\n[cluster]\nconfiguration = '\(expected.configuration)'\nsha256 = '\(expected.sha256)'\n".utf8)
        try data.write(to: file); #expect(chmod(file.path, 0o600) == 0)
        #expect(try ClusterConfigurationStore.installedReference(providerConfiguration: file) == expected)
        #expect(try Data(contentsOf: file) == data)
        for invalid in [Data("[broken".utf8), Data("[provider]\nname='fixture'\n".utf8), Data([255])] {
            try invalid.write(to: file)
            #expect(throws: (any Error).self) { _ = try ClusterConfigurationStore.installedReference(providerConfiguration: file) }
            #expect(try Data(contentsOf: file) == invalid)
        }
        try data.write(to: file); #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: (any Error).self) { _ = try ClusterConfigurationStore.installedReference(providerConfiguration: file) }
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        #expect(throws: (any Error).self) { _ = try ClusterConfigurationStore.installedReference(providerConfiguration: alias) }
    }
}
