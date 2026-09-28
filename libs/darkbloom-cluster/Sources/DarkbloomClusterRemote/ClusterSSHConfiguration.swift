import Foundation
import Darwin
import DarkbloomClusterProcess

/// Explicit installed-host configuration. Authentication is performed by OpenSSH
/// with configured host-key/public-key files, never an ad-hoc crypto scheme.
public struct ClusterSSHConfiguration: Sendable {
    public let host: String
    public let user: String
    public let port: Int
    public let knownHostsFile: URL
    public let identityFile: URL
    public let installedDarkbloom: String

    public init(host: String, user: String, port: Int, knownHostsFile: URL, identityFile: URL,
                installedDarkbloom: String) throws {
        func label(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 253 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            } && !value.hasPrefix("-")
        }
        func path(_ value: String) -> Bool {
            value.hasPrefix("/") && value.utf8.count <= 1024 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0)
            } && !value.split(separator: "/").contains("..")
        }
        guard label(host), label(user), (1...65_535).contains(port), knownHostsFile.isFileURL, identityFile.isFileURL,
              path(knownHostsFile.path), path(identityFile.path), path(installedDarkbloom) else { throw OwnerWire.invalid("Unsafe SSH configuration") }
        self.host = host; self.user = user; self.port = port; self.knownHostsFile = knownHostsFile
        self.identityFile = identityFile; self.installedDarkbloom = installedDarkbloom
    }
    public func launch() throws -> ClusterWorkerLaunch {
        // Do not read private key bytes. Refuse links/unowned/group writable trust
        // files; configured files remain managed by configure, not this launch.
        for url in [knownHostsFile, identityFile] {
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == geteuid(),
                  s.st_mode & 0o022 == 0, s.st_nlink == 1 else { throw OwnerWire.invalid("Unsafe configured SSH trust file") }
        }
        let options = ["BatchMode=yes", "StrictHostKeyChecking=yes", "UserKnownHostsFile=\(knownHostsFile.path)",
            "GlobalKnownHostsFile=/dev/null", "IdentitiesOnly=yes", "IdentityAgent=none", "PreferredAuthentications=publickey",
            "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "ForwardAgent=no", "ForwardX11=no",
            "ControlMaster=no", "ControlPath=none", "ControlPersist=no", "ProxyCommand=none", "ProxyJump=none",
            "PermitLocalCommand=no", "ClearAllForwardings=yes", "UpdateHostKeys=no", "ConnectionAttempts=1",
            "ConnectTimeout=5", "ServerAliveInterval=5", "ServerAliveCountMax=2", "RequestTTY=no"]
        var args = ["-F", "/dev/null", "-T"]
        for option in options { args += ["-o", option] }
        args += ["-i", identityFile.path, "-p", String(port), "-l", user, "--", host,
                 "exec \(installedDarkbloom) cluster worker-owner --stdio"]
        return .init(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: args,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"])
    }
}
