import Darwin
import Foundation
import Testing
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import ProviderCore

/// The cluster service's two listeners follow a pairing made while it runs (2026-10-31: after the two Macs paired
/// again, the member's service refused every lease and the wizard's reading with `handshakeRejected` until it was
/// restarted). The actual service keys real listeners on loopback, on ports of their own, from real pairing ceremonies
/// stored in a private home. The other Mac dials with its copy of the pairing's key, without the per-user request lock
/// that `ClusterSetupLinkExchange.command` takes and any cluster service running on this Mac shares.
@Suite(.serialized)
struct ClusterServicePairingChangeTests {
    typealias Signer = ClusterPairingProviderTests.SoftwareSigner
    typealias Exchange = ClusterSetupLinkExchange

    @Test func bothListenersAnswerAPairingMadeWhileTheServiceRuns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let thisMac = Signer(), otherMac = Signer()
        let first = try fixture.pair(thisMac, otherMac)
        #expect(fixture.tick() == ["answering the paired Mac over the cable"])
        for listener in fixture.listeners { #expect(fixture.refusal(first, on: listener) == nil) }

        let second = try fixture.pair(thisMac, otherMac)
        #expect(second.identity != first.identity && second.linkEpoch != first.linkEpoch,
                "pairing the same two Macs again is another pairing")
        // What the other Mac met until the service was restarted: its new pairing refused at the handshake.
        for listener in fixture.listeners {
            #expect(fixture.refusal(second, on: listener)?.contains("refused (handshakeRejected)") == true)
        }
        #expect(fixture.tick() == ["this Mac's pairing changed (provider-pair): answering the paired Mac with the new one",
                                   "answering the paired Mac over the cable"])
        for listener in fixture.listeners {
            #expect(fixture.refusal(second, on: listener) == nil, "the new pairing is answered on port \(listener.port)")
            #expect(fixture.refusal(first, on: listener)?.contains("refused (handshakeRejected)") == true,
                    "the earlier pairing is refused on port \(listener.port)")
        }
    }

    @Test func bothListenersStopWhenThisMacIsNoLongerPaired() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pairing = try fixture.pair(Signer(), Signer())
        _ = fixture.tick()
        for listener in fixture.listeners { try #require(fixture.refusal(pairing, on: listener) == nil) }

        _ = try fixture.pairingStore.forget(peerPin: pairing.peerPin)
        #expect(fixture.tick() == ["this Mac is no longer paired: it stopped answering over the cable"])
        let stopped = fixture.responders()
        #expect(stopped.exchange == nil && stopped.control == nil)
        for listener in fixture.listeners {
            #expect(fixture.refusal(pairing, on: listener)?.contains("connectFailed") == true, "nothing listens on port \(listener.port)")
        }
        #expect(fixture.tick().isEmpty, "and nothing starts again while this Mac holds no pairing")
    }

    @Test func anUnchangedOrUnreadablePairingKeepsBothListeners() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pairing = try fixture.pair(Signer(), Signer())
        _ = fixture.tick()
        let started = fixture.responders()
        for _ in 0..<3 { #expect(fixture.tick().isEmpty) }
        // A pairing store that cannot be read is not taken for no pairing, as an unreadable setup record is not taken
        // for a stop.
        chmod(fixture.pairingStore.directory.path, 0o755)
        #expect(fixture.tick().isEmpty)
        chmod(fixture.pairingStore.directory.path, 0o700)
        let kept = fixture.responders()
        #expect(kept.exchange != nil && kept.exchange === started.exchange && kept.control != nil && kept.control === started.control,
                "no listener was started again")
        for listener in fixture.listeners { #expect(fixture.refusal(pairing, on: listener) == nil) }
    }

    /// The claim of a node built before this Mac paired again under a new key of its own still names the other Mac: only
    /// its local identity tells that it belongs to the earlier pairing.
    @Test func aControlNodeOfThisMacsEarlierKeyIsDropped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let otherMac = Signer()
        let earlier = try fixture.pair(Signer(), otherMac)
        try fixture.lead(earlier)
        fixture.service.lock.withLock { fixture.service.localHardware = ("fixture", 1 << 30, 1, .unknown) }
        fixture.service.ensureControl(pairing: earlier)
        #expect(fixture.service.lock.withLock { fixture.service.control?.localID } == earlier.localMemberID)

        let current = try fixture.pair(Signer(), otherMac)
        #expect(current.localPin != earlier.localPin && current.peerPin == earlier.peerPin)
        try fixture.lead(current)
        fixture.service.ensureControl(pairing: current)
        let node = fixture.service.lock.withLock { fixture.service.control }
        #expect(node?.localID == current.localMemberID)
        #expect(node?.claim.members.contains(earlier.localMemberID) == false)
    }

    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ line: String) { lock.withLock { said.append(line) } }
        var lines: [String] { lock.withLock { said } }
    }

    private struct Fixture {
        let home: URL
        let service: ClusterService
        let records: ClusterSetupStore
        let listening: ClusterService.Listening
        let loopback: ClusterLinkInterfaceSelection
        /// The other Mac's own store: the ceremony stores its side there.
        let peerStore: ClusterPairingStore
        var pairingStore: ClusterPairingStore { .default(home: home) }
        var listeners: [(port: UInt16, label: String)] {
            [(listening.exchangePort, Exchange.exchangeLabel), (listening.controlPort, Exchange.controlLabel)]
        }

        init() throws {
            home = try NativePairMemberFixture.privateRoot()
            let paths = try ClusterUserPaths(homeDirectory: home)
            records = ClusterSetupStore(paths: .init(paths: paths))
            loopback = try ClusterLinkInterfaceAdmission.select(interface: "lo0", localAddress: nil, peerAddress: nil,
                policy: .loopbackForTests, inspector: ClusterLinkSystemInterfaceInspector())
            // Loopback ports of their own, below the production listeners' (`ClusterSetupLinkExchange.port`, `.controlPort`).
            let exchangePort = UInt16(46_100 + getpid() % 300 * 2)
            listening = .init(exchangePort: exchangePort, controlPort: exchangePort + 1, policy: .loopbackForTests,
                              selection: loopback)
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: home.appendingPathComponent("provider.toml"),
                darkbloomExecutable: home.appendingPathComponent("not-executed"), sessionArguments: [], pair: nil, dryRun: true,
                version: "fixture")
            service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: []), paths: paths,
                                     listening: listening)
            peerStore = ClusterPairingStore(directory: home.appendingPathComponent("other-mac/cluster-pairing", isDirectory: true))
        }

        /// One ceremony with the provider's participants, stored in both Macs' stores; this Mac's pairing after it.
        func pair(_ thisMac: Signer, _ otherMac: Signer) throws -> Exchange.Pairing {
            _ = try ClusterPairingProviderTests.pair(thisMac, otherMac, stores: (pairingStore, peerStore))
            return try #require(try Exchange.pairing(store: pairingStore))
        }

        /// The onboarding's record for `pairing`, with this Mac driving it, as `darkbloom cluster` writes it.
        func lead(_ pairing: Exchange.Pairing) throws {
            _ = try records.updateRecord {
                $0.leadership = .init(role: ClusterOnboardingRole.leader.rawValue, leaderPin: pairing.localPin,
                                      peerPin: pairing.peerPin, peerName: "the other Mac", since: "fixture")
            }
        }

        /// One supervision tick of both listeners, with their checks due; the lines the service said.
        func tick() -> [String] {
            let said = Said()
            service.lock.withLock { service.responderCheck = .distantPast; service.controlCheck = .distantPast }
            service.ensureResponder { said.add($0) }
            service.ensureControlResponder { said.add($0) }
            return said.lines
        }

        func responders() -> (exchange: Exchange.Responder?, control: Exchange.Responder?) {
            service.lock.withLock { (service.responder, service.controlResponder) }
        }

        /// Nil when the listener answers the other Mac's copy of `pairing` (any reply follows an accepted handshake),
        /// else why it did not. The copy is the pairing's key with the pins the other way round.
        func refusal(_ pairing: Exchange.Pairing, on listener: (port: UInt16, label: String)) -> String? {
            let theirs = Exchange.Pairing(localPin: pairing.peerPin, peerPin: pairing.localPin, clusterID: pairing.clusterID,
                linkEpoch: pairing.linkEpoch, edgeID: pairing.edgeID, secretFile: pairing.secretFile, secret: pairing.secret)
            do {
                let session = try Exchange.Session(pairing: theirs, selection: loopback, peerAddress: .loopback, port: listener.port,
                                                   policy: .loopbackForTests, label: listener.label)
                defer { session.close() }
                _ = try session.request(tag: Exchange.commandTag, Data("not a command".utf8), reply: Exchange.commandReplyTag, seconds: 2)
                return nil
            } catch let failure as ClusterSetupFailure {
                return failure.text
            } catch {
                return "\(error)"
            }
        }

        func remove() {
            let running = responders()
            running.exchange?.stop()
            running.control?.stop()
            try? FileManager.default.removeItem(at: home)
        }
    }
}
