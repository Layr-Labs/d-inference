import Foundation
import Darwin

/// The owner-only record of aliases the fix added, on real files under a
/// fixture home directory inside the checkout.
extension ClusterLinkCheck {
    private static func mode(_ url: URL) -> mode_t? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value.st_mode & 0o7777 : nil
    }

    private static func refused(_ label: String, line: Int = #line, _ body: () throws -> Void) {
        do { try body(); expect(false, "\(label) was accepted", line: line) } catch { expect(true, label, line: line) }
    }

    static func aliasRecordFile() {
        guard let first = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20"),
              let second = ClusterLinkLocalAddress(dottedDecimal: "169.254.30.40") else { expect(false, "fixture addresses"); return }
        // The strict file policy refuses symlinked path components such as /var,
        // so the fixture home lives under the working directory.
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("cluster-link-check-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let paths = try ClusterUserPaths(homeDirectory: home)
            let store = ClusterLinkAliasStore(paths: paths)
            let file = paths.deviceDirectory.appendingPathComponent("link-alias.json")

            expectEqual(try store.load(), ClusterLinkAliasRecord(), "no record yet")
            expect(!FileManager.default.fileExists(atPath: paths.deviceDirectory.path), "reading creates nothing")

            let one = ClusterLinkAliasRecord(aliases: [.init(interface: "en6", address: first)])
            try store.update { $0 = one }
            expectEqual(mode(file), 0o600, "record is owner-only")
            expectEqual(mode(paths.deviceDirectory), 0o700, "record directory is owner-only")
            expectEqual(try store.load(), one, "record round trip")
            expectEqual(try ClusterLinkAliasRecord.decode(ClusterConfigurationFiles.read(file, maximum: 4096, privateMode: true)), one,
                "the strict private reader accepts the record")
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            expect(text.contains("\"schema\":\"darkbloom_cluster_link_alias_v1\"") && text.contains("\"interface\":\"en6\"")
                && text.contains("\"address\":\"169.254.10.20\""), "record names the interface and address it applied")

            let two = ClusterLinkAliasRecord(aliases: [.init(interface: "en5", address: second), .init(interface: "en6", address: first)])
            try store.update { $0 = two }
            expectEqual(try store.load(), two, "replaced record")
            expectEqual(mode(file), 0o600, "a replaced record stays owner-only")
            try store.update { $0 = ClusterLinkAliasRecord() }
            expectEqual(try store.load(), ClusterLinkAliasRecord(), "an emptied record")
            expectEqual(mode(file), 0o600, "an emptied record stays owner-only")
            expect((try? FileManager.default.contentsOfDirectory(atPath: paths.deviceDirectory.path))?
                .allSatisfy { $0 == "link-alias.json" || $0 == "link-alias.json.lock" } == true, "no staged file is left behind")

            // A change applies to what is on disk at that moment, so an entry
            // another command added in between is kept.
            try store.update { $0 = one }
            try store.update { $0.set(.init(interface: "en5", address: second)) }
            expectEqual(try store.load().aliases.map(\.interface), ["en6", "en5"], "an update keeps the entries it does not touch")
            try store.update { $0.forget(interface: "en5") }
            expectEqual(try store.load(), one, "an update removes only what it names")

            // A record that others can read, or that is not a plain file, is refused.
            expect(chmod(file.path, 0o644) == 0, "fixture mode")
            refused("a group/world-readable record") { _ = try store.load() }
            refused("changing a group/world-readable record") { try store.update { $0 = ClusterLinkAliasRecord() } }
            expect(chmod(file.path, 0o600) == 0, "fixture mode")
            expectEqual(try store.load(), one, "owner-only again")
            // Nor is an address written into a directory that others can read.
            expect(chmod(paths.deviceDirectory.path, 0o755) == 0, "fixture mode")
            refused("saving into a group/world-readable directory") { try store.update { $0 = two } }
            expect(chmod(paths.deviceDirectory.path, 0o700) == 0, "fixture mode")
            expectEqual(try store.load(), one, "the refused save changed nothing")
            let moved = paths.deviceDirectory.appendingPathComponent("moved.json")
            try FileManager.default.moveItem(at: file, to: moved)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
            refused("a symlinked record") { _ = try store.load() }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: moved, to: file)

            // Nothing but validated names and link-local addresses can come out of a record.
            func decoding(_ json: String) throws -> ClusterLinkAliasRecord { try ClusterLinkAliasRecord.decode(Data(json.utf8)) }
            let schema = "\"schema\":\"darkbloom_cluster_link_alias_v1\""
            expectEqual(try decoding("{\"aliases\":[{\"address\":\"169.254.10.20\",\"interface\":\"en6\"}],\(schema)}"), one, "canonical record")
            for (label, json) in [
                ("hostile interface", "{\"aliases\":[{\"address\":\"169.254.10.20\",\"interface\":\"en6; id\"}],\(schema)}"),
                ("quoted interface", "{\"aliases\":[{\"address\":\"169.254.10.20\",\"interface\":\"en6\\\" with administrator privileges\"}],\(schema)}"),
                ("address outside link-local", "{\"aliases\":[{\"address\":\"192.0.2.10\",\"interface\":\"en6\"}],\(schema)}"),
                ("address with a suffix", "{\"aliases\":[{\"address\":\"169.254.10.20 -alias; id\",\"interface\":\"en6\"}],\(schema)}"),
                ("reserved address", "{\"aliases\":[{\"address\":\"169.254.0.20\",\"interface\":\"en6\"}],\(schema)}"),
                ("another schema", "{\"aliases\":[],\"schema\":\"darkbloom_cluster_link_alias_v2\"}"),
                ("missing schema", "{\"aliases\":[]}"),
                ("unknown field", "{\"aliases\":[],\"command\":\"id\",\(schema)}"),
                ("unknown alias field", "{\"aliases\":[{\"address\":\"169.254.10.20\",\"interface\":\"en6\",\"netmask\":\"0\"}],\(schema)}"),
                ("one port twice", "{\"aliases\":[{\"address\":\"169.254.10.20\",\"interface\":\"en6\"},{\"address\":\"169.254.30.40\",\"interface\":\"en6\"}],\(schema)}"),
                ("not an object", "[]"), ("empty", ""), ("trailing data", "{\"aliases\":[],\(schema)} {}"),
            ] {
                refused(label) { _ = try decoding(json) }
            }
            try Data("{\"aliases\":[{\"address\":\"169.254.10.20\",\"interface\":\"en6; id\"}],\(schema)}".utf8).write(to: file)
            expect(chmod(file.path, 0o600) == 0, "fixture mode")
            refused("a tampered record file") { _ = try store.load() }
            refused("changing a tampered record file") { try store.update { $0.forget(interface: "en6") } }
        } catch {
            expect(false, "alias record fixture failed: \(error)")
        }
    }
}
