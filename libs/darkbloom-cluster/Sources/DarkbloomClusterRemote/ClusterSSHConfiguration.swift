import Foundation
import Darwin
import DarkbloomClusterProcess

/// Explicit installed-host configuration. Authentication is performed by OpenSSH
/// with configured host-key/public-key files, never an ad-hoc crypto scheme.
///
/// The one configured identity file is the only key offered, and by default
/// no agent is consulted. An operator's key is commonly protected by a
/// passphrase kept in the macOS login keychain; `UseKeychain=yes` lets OpenSSH
/// itself read that passphrase for this identity file, as it does for an
/// interactive login. It offers no other key and prompts for nothing: without
/// a stored passphrase the connection fails as before.
///
/// The keychain hands the passphrase out only while it is unlocked; once it
/// locks (after sleep, on some Macs) OpenSSH reports "User interaction is not
/// allowed" and the route fails although the operator's own SSH agent still
/// holds the key. An operator may therefore allow that agent to serve the
/// configured identity: `DARKBLOOM_CLUSTER_SSH_AGENT=1` with `SSH_AUTH_SOCK`
/// naming a socket this user owns. `IdentitiesOnly=yes` still limits what is
/// offered to the configured identity, the agent is never forwarded, and no
/// private key bytes are read here either way.
public struct ClusterSSHConfiguration: Sendable {
    public let host: String
    public let user: String
    public let port: Int
    public let knownHostsFile: URL
    public let identityFile: URL
    public let installedDarkbloom: String
    /// The agent socket the operator allowed to serve the configured identity; nil, the default, consults none.
    public let identityAgent: String?

    public init(host: String, user: String, port: Int, knownHostsFile: URL, identityFile: URL,
                installedDarkbloom: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func label(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 253 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            } && !value.hasPrefix("-")
        }
        let path = Self.safePath
        guard label(host), label(user), (1...65_535).contains(port), knownHostsFile.isFileURL, identityFile.isFileURL,
              path(knownHostsFile.path), path(identityFile.path), path(installedDarkbloom) else { throw OwnerWire.invalid("Unsafe SSH configuration") }
        self.host = host; self.user = user; self.port = port; self.knownHostsFile = knownHostsFile
        self.identityFile = identityFile; self.installedDarkbloom = installedDarkbloom
        identityAgent = Self.allowedAgentSocket(environment)
    }

    /// The operator's own agent socket, only when they allowed it and it is
    /// a socket this user owns at a plain absolute path.
    static func allowedAgentSocket(_ environment: [String: String]) -> String? {
        guard environment["DARKBLOOM_CLUSTER_SSH_AGENT"] == "1", let socket = environment["SSH_AUTH_SOCK"], safePath(socket) else { return nil }
        var s = stat()
        guard lstat(socket, &s) == 0, s.st_mode & S_IFMT == S_IFSOCK, s.st_uid == geteuid() else { return nil }
        return socket
    }
    /// An absolute path of letters, digits, `-`, `.`, `_` and `/` with no
    /// `..` component: nothing a remote shell would read as anything else.
    static func safePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 1024 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0)
        } && !value.split(separator: "/").contains("..")
    }

    public func launch() throws -> ClusterWorkerLaunch {
        try launch(remoteCommand: "exec \(installedDarkbloom) cluster worker-owner --stdio")
    }

    /// The same pinned route for one metadata-only question to the peer: its
    /// installed plan tool printing that Mac's device profile. The tool reads
    /// system counters only; no model is loaded and nothing is started. The
    /// path is held to the same character rule as the installed owner's, and
    /// the two arguments are fixed here, so the remote command line carries
    /// nothing a caller composed.
    public func describeDevice(planTool: String) throws -> ClusterWorkerLaunch {
        guard Self.safePath(planTool) else { throw OwnerWire.invalid("Unsafe SSH configuration") }
        return try launch(remoteCommand: "exec \(planTool) device --json")
    }

    /// The setup wizard's question to the peer: that Mac's own report of
    /// itself (hardware, cable, saved setup, models, memory), printed by its
    /// installed darkbloom. Read-only there. The two paths name where that
    /// Mac's worker and models are, for a peer that has no setup yet; both are
    /// held to the same character rule, so the command line carries nothing a
    /// remote shell would read as anything but a path.
    public func setupReport(workerExecutable: String, modelDirectory: String) throws -> ClusterWorkerLaunch {
        guard Self.safePath(workerExecutable), Self.safePath(modelDirectory) else { throw OwnerWire.invalid("Unsafe SSH configuration") }
        return try launch(remoteCommand: "exec \(installedDarkbloom) cluster report --json --worker \(workerExecutable) --model-dir \(modelDirectory)")
    }

    /// The setup wizard's delivery of the peer's own setup: the peer's
    /// installed darkbloom reads it from standard input, checks it with its
    /// strict codecs and keeps it for that Mac's person to approve. Nothing is
    /// trusted or saved there without that approval.
    public func sendSetup() throws -> ClusterWorkerLaunch {
        try launch(remoteCommand: "exec \(installedDarkbloom) cluster inbox --receive")
    }

    private func launch(remoteCommand: String) throws -> ClusterWorkerLaunch {
        // Do not read private key bytes. Refuse links/unowned/group writable trust
        // files; configured files remain managed by configure, not this launch.
        for url in [knownHostsFile, identityFile] {
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == geteuid(),
                  s.st_mode & 0o022 == 0, s.st_nlink == 1 else { throw OwnerWire.invalid("Unsafe configured SSH trust file") }
        }
        let options = ["BatchMode=yes", "StrictHostKeyChecking=yes", "UserKnownHostsFile=\(knownHostsFile.path)",
            "GlobalKnownHostsFile=/dev/null", "IdentitiesOnly=yes", "IdentityAgent=\(identityAgent ?? "none")", "UseKeychain=yes", "PreferredAuthentications=publickey",
            "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "ForwardAgent=no", "ForwardX11=no",
            "ControlMaster=no", "ControlPath=none", "ControlPersist=no", "ProxyCommand=none", "ProxyJump=none",
            "PermitLocalCommand=no", "ClearAllForwardings=yes", "UpdateHostKeys=no", "ConnectionAttempts=1",
            "ConnectTimeout=5", "ServerAliveInterval=5", "ServerAliveCountMax=2", "RequestTTY=no"]
        var args = ["-F", "/dev/null", "-T"]
        for option in options { args += ["-o", option] }
        args += ["-i", identityFile.path, "-p", String(port), "-l", user, "--", host, remoteCommand]
        return .init(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: args,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"])
    }
}
