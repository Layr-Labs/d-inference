import Foundation
import Darwin

@main enum ConfigurationFilesCheck {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }
    static func rejected(_ action: () throws -> Void) throws {
        do { try action(); throw Failure(message: "Invalid file operation succeeded") }
        catch is ClusterConfigurationError { }
    }
    static func main() throws {
        // Keep the fixture under this private working directory: Foundation may
        // canonicalize macOS /private/var back to the /var symlink, which this
        // deliberately link-free store refuses.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("cluster-config-check-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ClusterConfigurationFiles.directory(root, privateMode: true)
        defer { Darwin.close(directory.descriptor) }
        let original = Data("original\n".utf8), replacement = Data(repeating: 88, count: 8192)

        try ClusterConfigurationFiles.publish(original, parent: directory, name: "immutable.json", maximum: 8192)
        try ClusterConfigurationFiles.publish(original, parent: directory, name: "immutable.json", maximum: 8192)
        try require(try ClusterConfigurationFiles.read(root.appendingPathComponent("immutable.json"), maximum: 8192, privateMode: true) == original, "Immutable content changed")
        var metadata = stat()
        try require(lstat(root.appendingPathComponent("immutable.json").path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600 && metadata.st_nlink == 1, "Publication permissions/links differ")

        try rejected { try ClusterConfigurationFiles.publish(replacement, parent: directory, name: "immutable.json", maximum: 8192) }
        try require(try ClusterConfigurationFiles.readAt(directory, name: "immutable.json", maximum: 8192) == original, "Refusal replaced immutable content")

        let provider = root.appendingPathComponent("provider.toml")
        try ClusterConfigurationFiles.update(provider, maximum: 8192) { old in
            try require(old == nil, "New provider unexpectedly exists"); return original
        }
        try rejected {
            try ClusterConfigurationFiles.update(provider, maximum: 8192) { _ in throw ClusterConfigurationError.invalid("fixture refusal") }
        }
        try require(try ClusterConfigurationFiles.read(provider, maximum: 8192) == original, "Failed transform lost previous provider config")
        try ClusterConfigurationFiles.update(provider, maximum: 8192) { old in
            try require(old == original, "Update did not reload original"); return replacement
        }
        try require(try ClusterConfigurationFiles.read(provider, maximum: 8192) == replacement, "Atomic replacement differs")

        let fifo = root.appendingPathComponent("fifo"), link = root.appendingPathComponent("link"), hard = root.appendingPathComponent("hard")
        try require(mkfifo(fifo.path, 0o600) == 0, "Cannot create FIFO fixture")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: provider)
        try FileManager.default.linkItem(at: provider, to: hard)
        for input in [fifo, link, hard, provider, root] {
            try rejected { _ = try ClusterConfigurationFiles.read(input, maximum: 8192) }
        }
        try FileManager.default.removeItem(at: hard)
        let empty = root.appendingPathComponent("empty"), large = root.appendingPathComponent("large")
        try Data().write(to: empty); try Data(repeating: 1, count: 8193).write(to: large)
        for input in [empty, large] { try rejected { _ = try ClusterConfigurationFiles.read(input, maximum: 8192) } }

        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: child)
        try rejected { _ = try ClusterConfigurationFiles.directory(parentLink) }
        try require(chmod(child.path, 0o777) == 0, "Cannot make unsafe directory fixture")
        try rejected { _ = try ClusterConfigurationFiles.directory(child) }
        try require(chmod(child.path, 0o700) == 0, "Cannot restore directory fixture")

        try ClusterConfigurationFiles.withLock(directory, name: "contended.lock") {
            do {
                try ClusterConfigurationFiles.withLock(directory, name: "contended.lock") { }
                throw Failure(message: "Contended lock was admitted")
            } catch ClusterConfigurationError.busy { }
        }
        try ClusterConfigurationFiles.withLock(directory, name: "contended.lock") { }

        let credential = root.appendingPathComponent("key")
        try Data("not-a-real-key".utf8).write(to: credential)
        try require(chmod(credential.path, 0o600) == 0, "Cannot set key mode")
        try ClusterConfigurationFiles.credentialMetadata(credential, privateMode: true)
        try require(chmod(credential.path, 0o644) == 0, "Cannot change key mode")
        try rejected { try ClusterConfigurationFiles.credentialMetadata(credential, privateMode: true) }
        try rejected { try ClusterConfigurationFiles.credentialMetadata(fifo, privateMode: true) }

        let intervening = Data("external-writer\n".utf8)
        try rejected {
            try ClusterConfigurationFiles.update(provider, maximum: 8192) { _ in
                try intervening.write(to: provider)
                return original
            }
        }
        try require(try ClusterConfigurationFiles.read(provider, maximum: 8192) == intervening, "Outside-lock change was overwritten")
        try rejected { try ClusterConfigurationFiles.publish(original, parent: directory, name: "../escape", maximum: 8192) }
        try require(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".cluster-") }, "Staged file was not cleaned")

        let paths = try ClusterUserPaths(homeDirectory: root)
        let hash = String(repeating: "a", count: 64)
        try require(paths.deviceLeaseFile.path == root.path + "/.darkbloom/cluster-device/native-device.lease", "Device path is not canonical")
        try require(try paths.configurationURL(sha256: hash).lastPathComponent == hash + ".cluster.json", "Content address differs")
        try rejected { _ = try paths.configurationURL(sha256: "../other") }
        print("Configuration files: 9 actual-file groups passed; no native/model/network execution")
    }
}
