import Foundation
import DarkbloomClusterRemote
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// A fixed interface table: the Thunderbolt ports a check says exist, and nothing else.
    struct CablePortTable: ClusterLinkInterfaceInspecting {
        let ports: [String: ClusterLinkInterfaceFacts]
        func facts(forInterface name: String) throws -> ClusterLinkInterfaceFacts {
            guard let facts = ports[name] else { throw ClusterSetupFailure("no interface \(name)") }
            return facts
        }
    }

    /// The cable moved to another Thunderbolt port (owner pair, 2026-10-15: en3, then en1, then en2): a cluster service
    /// listener started on the old port is started again on the new one, and only then. Failing first on 06fe95998
    /// (no such rule: the listeners stayed on the port they started on, and the Macs stopped reaching each other).
    static func cableMovesToAnotherPort() throws {
        func port(_ name: String, _ index: UInt32, _ address: String) throws -> ClusterLinkInterfaceSelection {
            let facts = ClusterLinkInterfaceFacts(name: name, index: index, kind: .thunderbolt, bridgeMembers: nil,
                addresses: [.init(address: ClusterLinkIPv4Address(address)!, netmask: 0xFFFF_0000)])
            return try ClusterLinkInterfaceAdmission.select(interface: name, localAddress: nil, peerAddress: nil,
                policy: .thunderboltOnly, inspector: CablePortTable(ports: [name: facts]))
        }
        typealias X = ClusterSetupLinkExchange
        let first = try port("en1", 11, "10.219.1.2"), moved = try port("en2", 12, "10.219.1.2")
        let readdressed = try port("en1", 11, "10.219.7.2")
        expect(!X.cableMoved(bound: first, current: try port("en1", 11, "10.219.1.2")), "the same port and address: kept")
        expect(X.cableMoved(bound: first, current: moved), "another port: started again there")
        expect(X.cableMoved(bound: first, current: readdressed), "the same port with another address: started again")
        expect(!X.cableMoved(bound: first, current: nil), "no cable now: kept (it may come back on the same port)")
        expect(!X.cableMoved(bound: nil, current: moved), "no listener yet: nothing to move")
    }

    /// `darkbloom` run from the PATH is the installer's link (`~/.darkbloom/bin/darkbloom` -> the app's executable). A
    /// setup names the file itself as the owner, which the owner's start accepts; the link it refuses. Found on the
    /// 2x M4 Max / M5 Max pair 2026-10-15 ("Installed local owner is unsafe or not executable"); failing first on
    /// b34d13506, where the setup named the link.
    static func ownerIsTheFileNotThePathLink() throws {
        let root = scratch.appendingPathComponent("owner-path", isDirectory: true)
        let macOS = root.appendingPathComponent("Darkbloom.app/Contents/MacOS", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = macOS.appendingPathComponent("darkbloom")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let link = bin.appendingPathComponent("darkbloom")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Darkbloom.app/Contents/MacOS/darkbloom")
        let named = ClusterSetupMemberFacts.installedOwnerPath(link)
        var information = stat()
        expect(lstat(named, &information) == 0 && information.st_mode & S_IFMT == S_IFREG, "the setup names a regular file, not the link: \(named)")
        expect(URL(fileURLWithPath: named).lastPathComponent == "darkbloom" && named.hasSuffix("Darkbloom.app/Contents/MacOS/darkbloom"),
               "the file the link points at: \(named)")
        expect(ClusterSetupMemberFacts.installedOwnerPath(file) == file.resolvingSymlinksInPath().path, "a path that is the file stays the file")

        // The part's last error as the screen shows it: the words, not the Swift case around them.
        typealias T = ClusterConsoleText
        expect(T.plain(#"invalid("Installed local owner is unsafe or not executable")"#) == "Installed local owner is unsafe or not executable",
               "an error case's words")
        expect(T.plain("The cable is not ready") == "The cable is not ready", "plain words stay")
        expect(T.plain(#"invalid("a "quoted" word")"#) == #"invalid("a "quoted" word")"#, "a quote inside is left as it is")
        expect(T.plain(#"x.y("z")"#) == #"x.y("z")"#, "only a bare case name is taken off")
    }
}
