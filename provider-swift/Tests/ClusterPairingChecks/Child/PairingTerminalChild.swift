import Darwin
import Foundation
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// One Mac's `darkbloom cluster pair` for the pseudo-terminal checks: the
/// provider's terminal prompt and the real ceremony over loopback, with a
/// software key in place of the Secure Enclave key and a test attestation.
/// usage: PairingTerminalChild listen|connect <port> <store directory> <identity file> [lifetime seconds]
@main enum PairingTerminalChild {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, ["listen", "connect"].contains(arguments[1]), let port = UInt16(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: PairingTerminalChild listen|connect <port> <store> <identity> [lifetime]\n".utf8))
            exit(2)
        }
        guard ClusterPairingTerminal.isTerminal() else { print("Pairing needs a person at a terminal."); exit(2) }
        let role: ClusterPairingRole = arguments[1] == "listen" ? .listener : .connector
        let store = ClusterPairingStore(directory: URL(fileURLWithPath: arguments[3]))
        guard let identity = try? SoftwareIdentity(persistedAt: URL(fileURLWithPath: arguments[4])) else { exit(2) }
        var options = ClusterLinkPairing.Options(role: role, interface: "lo0", peerAddress: role == .connector ? .loopback : nil)
        options.port = port; options.policy = .loopbackForTests
        options.lifetimeSeconds = arguments.count > 5 ? Double(arguments[5]) ?? 60 : 60
        let terminal = ClusterPairingTerminal()
        terminal.say("This Mac:       test \(role.rawValue); key pin \(ClusterPairingPin.of(identityKey: identity.identityPublicKey).prefix(16))…")
        let callbacks = terminal.callbacks { _, port in "darkbloom cluster pair --connect 127.0.0.1 --port \(port)" }
        let result = ClusterLinkPairing.run(options: options,
            participant: TestPairing.storeBacked(identity, name: "Test \(role.rawValue)", store: store, clusterID: role == .listener ? "pty-pair" : nil),
            hooks: TestPairing.hooks, store: store, callbacks: callbacks)
        terminal.restoreMode()
        for line in ClusterPairingTerminal.summary(result) { terminal.say(line) }
        if case .success = result { exit(0) }
        exit(1)
    }
}
