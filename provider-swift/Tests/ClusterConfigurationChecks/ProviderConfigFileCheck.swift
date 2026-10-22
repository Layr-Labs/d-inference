import Foundation
import Darwin

/// The provider configuration writer against the strict reader the cluster
/// commands use: whatever an ordinary save leaves on disk must stay readable
/// by `--distributed` startup, the installed owner and `cluster status`.
@main enum ProviderConfigFileCheck {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }

    static func mode(_ url: URL) throws -> mode_t {
        var value = stat()
        try require(lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG, "\(url.lastPathComponent) is not a regular file")
        return value.st_mode & 0o7777
    }

    static func strictRead(_ url: URL) throws -> Data {
        try ClusterConfigurationFiles.read(url, maximum: 1_048_576, privateMode: true)
    }

    static func requireFailure(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: message)
    }

    static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    static func main() throws {
        // A checkout-local directory: the strict reader refuses the /var symlink
        // in the system temporary path.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("provider-config-file-check-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data("[provider]\nname = 'fixture'\n".utf8), second = Data("[provider]\nname = 'changed'\n".utf8)

        // A first save creates the file; it must already be owner-only.
        let created = root.appendingPathComponent("created.toml")
        try ProviderConfigFile.replace(created, with: first)
        try require(try mode(created) == 0o600, "a new provider configuration is mode \(String(try mode(created), radix: 8)), not 600")
        try require(try strictRead(created) == first, "the strict cluster reader refused a newly saved configuration")

        // A later save keeps it owner-only.
        try ProviderConfigFile.replace(created, with: second)
        try require(try mode(created) == 0o600 && strictRead(created) == second, "a rewritten configuration lost mode 600")

        // A file left group/world-readable by an earlier release is tightened by the next save.
        let loose = root.appendingPathComponent("loose.toml")
        try first.write(to: loose)
        try require(chmod(loose.path, 0o644) == 0, "fixture mode")
        try ProviderConfigFile.replace(loose, with: second)
        try require(try mode(loose) == 0o600 && strictRead(loose) == second, "a loose configuration was not tightened to 600")

        // A stricter existing mode is kept, never widened to 600.
        let readOnly = root.appendingPathComponent("read-only.toml")
        try first.write(to: readOnly)
        try require(chmod(readOnly.path, 0o400) == 0, "fixture mode")
        try ProviderConfigFile.replace(readOnly, with: second)
        try require(try mode(readOnly) == 0o400 && strictRead(readOnly) == second, "a read-only configuration was widened")

        // The replacement is one rename: no staged file is left behind, and a
        // failed save leaves the previous bytes and mode untouched.
        try require(try names(in: root) == ["created.toml", "loose.toml", "read-only.toml"], "a staged file was left behind")
        let sealed = root.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let kept = sealed.appendingPathComponent("provider.toml")
        try ProviderConfigFile.replace(kept, with: first)
        try require(chmod(sealed.path, 0o500) == 0, "fixture directory mode")
        defer { _ = chmod(sealed.path, 0o700) }
        try requireFailure("a save into a read-only directory succeeded") { try ProviderConfigFile.replace(kept, with: second) }
        try require(try mode(kept) == 0o600 && strictRead(kept) == first, "a failed save changed the configuration")
        try require(try names(in: sealed) == ["provider.toml"], "a failed save left a staged file behind")

        // A save that fails only at the rename, after its sibling is fully
        // written, removes that sibling.
        let occupied = root.appendingPathComponent("occupied.toml", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try requireFailure("a save over a directory succeeded") { try ProviderConfigFile.replace(occupied, with: second) }
        try require(try names(in: root) == ["created.toml", "loose.toml", "occupied.toml", "read-only.toml", "sealed"]
            && names(in: occupied).isEmpty, "a save that failed at the rename left its staged file behind")
        print("Provider configuration file: owner-only create/rewrite/tighten, kept read-only mode and atomic failure passed")
    }
}
