import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// Where one Mac's installation is and its own address on the link, so the
/// leader can write both Macs' setups without SSH (PROD-PLAN S17/S07, owner
/// gate "no SSH and no network settings in the user path"). It travels only
/// inside a link control session keyed by the pairing's edge secret, and is
/// never shown, logged or kept beside the wizard's record.
public struct ClusterSetupMemberFacts: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_setup_member_facts_v1"
    public var schema = ClusterSetupMemberFacts.schemaName
    /// The member ID both setups use for this Mac, derived from its pairing pin.
    public var memberID: String
    /// This Mac's IPv4 address on the cable port (Darkbloom's own 10.219 service address after link setup v2).
    public var linkAddress: String
    /// A label the setup carries; nothing dials it on a setup reached over the link.
    public var user: String
    public var ownerExecutable: String
    public var workerExecutable: String
    /// One model folder in this Mac's model directory; the plan swaps the folder name.
    public var modelDirectory: String
    public var runtimeBinarySHA256: String
    public var jacclDevice: String
    /// This Mac's own copy of the pairing's edge secret (an owner-only file).
    public var linkSecretFile: String

    public init(memberID: String, linkAddress: String, user: String, ownerExecutable: String, workerExecutable: String,
                modelDirectory: String, runtimeBinarySHA256: String, jacclDevice: String, linkSecretFile: String) {
        self.memberID = memberID; self.linkAddress = linkAddress; self.user = user; self.ownerExecutable = ownerExecutable
        self.workerExecutable = workerExecutable; self.modelDirectory = modelDirectory
        self.runtimeBinarySHA256 = runtimeBinarySHA256; self.jacclDevice = jacclDevice; self.linkSecretFile = linkSecretFile
    }

    /// The member ID a Mac gets from its pairing pin: the same on both Macs, no host or user name.
    public static func memberID(pin: String) -> String { "mac-" + String(pin.prefix(12)) }

    /// The darkbloom a setup names as this Mac's owner: the file itself, never the link the installer puts on the
    /// PATH (`~/.darkbloom/bin/darkbloom`). The owner's start refuses a symlink (`ClusterLocalOwnerConfiguration`), so
    /// a setup made by `darkbloom` run from the PATH could never start its leader part.
    public static func installedOwnerPath(_ executable: URL) -> String {
        executable.resolvingSymlinksInPath().path
    }

    func validate() throws {
        func plain(_ value: String, _ limit: Int = 1024) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
        guard schema == Self.schemaName, plain(memberID, 64), ClusterLinkIPv4Address(linkAddress) != nil, plain(user, 256),
              [ownerExecutable, workerExecutable, modelDirectory, linkSecretFile].allSatisfy({ plain($0) && $0.hasPrefix("/") }),
              runtimeBinarySHA256.count == 64, runtimeBinarySHA256.allSatisfy(\.isHexDigit),
              jacclDevice.hasPrefix("rdma_"), plain(jacclDevice, 64) else {
            throw ClusterSetupFailure("the other Mac described its installation with values this build does not accept")
        }
    }
}

/// The other Mac's answer to "who are you": its wizard report and its facts.
public struct ClusterSetupLinkAnswer: Codable, Sendable, Equatable {
    public var report: ClusterSetupReport
    public var facts: ClusterSetupMemberFacts
    public init(report: ClusterSetupReport, facts: ClusterSetupMemberFacts) { self.report = report; self.facts = facts }
}

/// The setup exchange of the guided flow over the paired link: the leader's
/// wizard asks the other Mac for its report and facts, and later hands it its
/// setup for its inbox. Both run on the link control channel, authenticated by
/// the pairing's edge secret under a key of their own (a setup-exchange epoch
/// derived from the pairing's link epoch), so an exchange session can never
/// authenticate a serving session and no Mac that did not pair is answered.
/// The other Mac is found on the cable by the pairing's discovery datagrams on
/// the exchange's own port: no address is typed and no SSH is used.
public enum ClusterSetupLinkExchange {
    public static let port: UInt16 = 47_422
    /// The control leader's lease (derived leadership, `ClusterControlNode`) on a listener of its own, keyed apart
    /// from the setup exchange: a renewal never supersedes a `darkbloom cluster` session on the exchange's listener,
    /// and never waits behind one.
    public static let controlPort: UInt16 = 47_423
    public static let exchangeLabel = "darkbloom-cluster-setup-exchange-v1"
    public static let controlLabel = "darkbloom-cluster-control-lease-v1"
    static let controlLockName = "darkbloom-cluster-control.lock"
    static let askTag: UInt16 = 0x5E01
    static let answerTag: UInt16 = 0x5E02
    static let deliverTag: UInt16 = 0x5E03
    static let receiptTag: UInt16 = 0x5E04
    /// A command from the cluster's leader to a member's cluster service (serve, stop, status, a test request).
    static let commandTag: UInt16 = 0x5E05
    static let commandReplyTag: UInt16 = 0x5E06
    static let maximumBytes = 1 << 20
    /// One chunk of a model copy (ClusterModelProvisioningLink): the largest body on the exchange.
    static let provisionChunkBytes = 4 << 20

    /// The one pairing this Mac uses, with its edge secret.
    public struct Pairing: Sendable {
        public let localPin: String
        public let peerPin: String
        public let clusterID: String
        /// The pairing's link epoch and edge, as stored (lowercase UUID text).
        public let linkEpoch: String
        public let edgeID: String
        /// This Mac's owner-only copy of the edge secret.
        public let secretFile: String
        let secret: Data
        init(localPin: String, peerPin: String, clusterID: String, linkEpoch: String, edgeID: String, secretFile: String, secret: Data) {
            self.localPin = localPin; self.peerPin = peerPin; self.clusterID = clusterID
            self.linkEpoch = linkEpoch; self.edgeID = edgeID; self.secretFile = secretFile; self.secret = secret
        }
        public var localMemberID: String { ClusterSetupMemberFacts.memberID(pin: localPin) }
        public var peerMemberID: String { ClusterSetupMemberFacts.memberID(pin: peerPin) }
    }

    /// Nil when this Mac never paired over the link. With several pairings, the newest.
    public static func pairing(store: ClusterPairingStore = .default()) throws -> Pairing? {
        guard let records = try store.load(), let record = records.pairings.max(by: { $0.pairedAt < $1.pairedAt }) else { return nil }
        return Pairing(localPin: records.localPin, peerPin: record.peerPin, clusterID: record.clusterID, linkEpoch: record.link.linkEpoch,
            edgeID: record.link.edgeID, secretFile: record.link.secretFile, secret: try store.edgeSecret(for: record))
    }

    /// The edge of the exchange, keyed apart from serving.
    static func edge(_ pairing: Pairing, peerAddress: ClusterLinkIPv4Address?, label: String = exchangeLabel) throws -> ClusterLinkControlEdge {
        guard let edgeID = UUID(uuidString: pairing.edgeID), let linkEpoch = UUID(uuidString: pairing.linkEpoch) else {
            throw ClusterSetupFailure("the pairing record names no usable link edge; pair again with `darkbloom cluster`")
        }
        let epoch = exchangeEpoch(linkEpoch, label: label)
        let key = try ClusterLinkControlKey.qualification(secret: pairing.secret, epoch: epoch, edgeID: edgeID)
        var limits = ClusterLinkControlLimits()
        // A model copy's chunk is the largest body on the exchange.
        limits.maximumBodyBytes = max(maximumBytes, provisionChunkBytes) + 4096
        return try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: peerAddress, limits: limits)
    }

    /// A UUID of its own for the exchange, derived from the pairing's link epoch.
    static func exchangeEpoch(_ linkEpoch: UUID, label: String = exchangeLabel) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(label.utf8))
        withUnsafeBytes(of: linkEpoch.uuid) { hasher.update(data: Data($0)) }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Answering (every paired Mac while its wizard is open)

    /// Answers the other Mac's wizard while this Mac's wizard is open: its
    /// report and facts, and a setup for the inbox (which approves nothing).
    public final class Responder: @unchecked Sendable {
        private let listener: ClusterLinkControlListener
        private let discovery: ClusterLinkPairingDiscovery.Responder
        private let edgeID: UUID
        /// The cable port and address it listens on (it never follows the cable to another port by itself).
        public let selection: ClusterLinkInterfaceSelection

        public init(pairing: Pairing, selection: ClusterLinkInterfaceSelection,
                    port: UInt16 = ClusterSetupLinkExchange.port, policy: ClusterLinkInterfacePolicy = .thunderboltOnly,
                    epochLabel: String = ClusterSetupLinkExchange.exchangeLabel,
                    answer: @escaping @Sendable () throws -> ClusterSetupLinkAnswer,
                    receive: @escaping @Sendable (Data) throws -> String,
                    command: (@Sendable (Data) throws -> Data)? = nil,
                    provision: (@Sendable (UInt16, Data) -> (UInt16, Data)?)? = nil) throws {
            let edge = try ClusterSetupLinkExchange.edge(pairing, peerAddress: nil, label: epochLabel)
            edgeID = edge.edgeID
            self.selection = selection
            let work = DispatchQueue(label: "darkbloom.cluster-setup.exchange")
            listener = try ClusterLinkControlListener(configuration: .init(interface: selection.interface,
                localAddress: selection.local.address, port: port, policy: policy, edges: [edge])) { event, peer in
                guard case .opaque(_, _, let tag, let data) = event, let peer else { return }
                // Off the channel's event queue: the report reads the disk and the doctor.
                work.async {
                    switch tag {
                    case ClusterSetupLinkExchange.askTag:
                        let reply: Data
                        do { reply = try JSONEncoder().encode(try answer()) } catch {
                            reply = Data(("error:" + ClusterConsoleText.bounded(String(describing: error), maximum: 200)).utf8)
                        }
                        _ = try? peer.sendOpaque(tag: ClusterSetupLinkExchange.answerTag, reply, timeout: .seconds(10))
                    case ClusterSetupLinkExchange.deliverTag:
                        let reply: String
                        do { reply = "ok:" + (try receive(data)) } catch {
                            reply = "error:" + ClusterConsoleText.bounded(String(describing: error), maximum: 200)
                        }
                        _ = try? peer.sendOpaque(tag: ClusterSetupLinkExchange.receiptTag, Data(reply.utf8), timeout: .seconds(10))
                    case ClusterSetupLinkExchange.commandTag:
                        // Only a cluster service takes commands; an open wizard answers that it does not.
                        var reply: Data
                        if let command {
                            do { reply = Data("ok:".utf8) + (try command(data)) } catch {
                                reply = Data(("error:" + ClusterConsoleText.bounded(String(describing: error), maximum: 300)).utf8)
                            }
                        } else {
                            reply = Data("error:this Mac's wizard takes no commands; its cluster service does".utf8)
                        }
                        if reply.count > ClusterSetupLinkExchange.maximumBytes { reply = Data("error:the answer is too large".utf8) }
                        _ = try? peer.sendOpaque(tag: ClusterSetupLinkExchange.commandReplyTag, reply, timeout: .seconds(10))
                    default:
                        // A model copy (cluster service only): every frame in order, each answered after it was written.
                        if let provision, let reply = provision(tag, data) {
                            _ = try? peer.sendOpaque(tag: reply.0, reply.1, timeout: .seconds(30))
                        }
                    }
                }
            }
            discovery = ClusterLinkPairingDiscovery.Responder(selection: selection, udpPort: port, tcpPort: port)
        }

        public func start() throws {
            _ = try listener.start()
            do { try discovery.start() } catch { listener.stop(); throw error }
        }

        public func stop() {
            discovery.stop()
            listener.stop()
        }
    }

    /// A listener bound to `bound` no longer reaches the other Mac once the cable moved: the active cable port, or that
    /// port's address, is another one now. It is then started again on `current`. A reading that finds no cable
    /// (`current` nil, e.g. while the cable is out) keeps it: the cable may come back on the same port.
    public static func cableMoved(bound: ClusterLinkInterfaceSelection?, current: ClusterLinkInterfaceSelection?) -> Bool {
        guard let bound, let current else { return false }
        return current.interface != bound.interface || current.local != bound.local
    }

    // MARK: - Asking (the Mac that plans)

    static let requestLockName = "darkbloom-cluster-exchange.lock"

    /// One request at a time from this user to the paired Mac. Its listener keeps one live session per edge and a
    /// newer session supersedes the older, whose answer then goes to the newer one and is lost: two processes on
    /// this Mac asking at once (the onboarding and the leader's cluster service) would take each other's answers
    /// away. Each request waits for the one under way (its own time and 30 s more) and then has the edge alone.
    static func oneAtATime<Value>(seconds: Double, lockName: String = requestLockName, _ request: () throws -> Value) throws -> Value {
        let held: ClusterConsoleInstanceLock
        do {
            held = try ClusterConsoleInstanceLock.acquire(directory: ClusterConsoleInstanceLock.userTemporaryDirectory(),
                fileName: lockName, waitSeconds: seconds + 30)
        } catch is ClusterConsoleInstanceLock.Held {
            throw ClusterSetupFailure("another request to the other Mac did not finish within \(Int(seconds + 30)) s")
        }
        return try withExtendedLifetime(held) { try request() }
    }

    /// One connected session to the other Mac's exchange, found on the cable.
    final class Session: @unchecked Sendable {
        let client: ClusterLinkControlClient
        let peerAddress: ClusterLinkIPv4Address
        private let lock = NSCondition()
        private var replies: [UInt16: Data] = [:]

        init(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address,
             port: UInt16, policy: ClusterLinkInterfacePolicy, label: String = ClusterSetupLinkExchange.exchangeLabel) throws {
            self.peerAddress = peerAddress
            let edge = try ClusterSetupLinkExchange.edge(pairing, peerAddress: peerAddress, label: label)
            let box = WeakSessionBox()
            client = try ClusterLinkControlClient(configuration: .init(interface: selection.interface,
                localAddress: selection.local.address, port: port, policy: policy, edge: edge)) { event, _ in
                guard case .opaque(_, _, let tag, let data) = event else { return }
                box.session?.deliver(tag: tag, data)
            }
            box.session = self
        }

        private func deliver(tag: UInt16, _ data: Data) {
            lock.withLock { replies[tag] = data; lock.broadcast() }
        }

        func request(tag: UInt16, _ body: Data, reply: UInt16, seconds: Double) throws -> Data {
            client.start()
            guard client.peer.waitUntilConnected(timeout: .milliseconds(Int64(seconds * 1000))) else {
                let reason = ClusterSetupLinkExchange.connectionFailure(refusal: client.lastRefusal, dial: client.lastConnectFailure)
                throw ClusterSetupFailure("the other Mac's wizard did not take the paired connection: \(reason)")
            }
            lock.withLock { replies[reply] = nil }
            _ = try client.peer.sendOpaque(tag: tag, body, timeout: .seconds(10))
            let deadline = Date(timeIntervalSinceNow: seconds)
            lock.lock()
            defer { lock.unlock() }
            while replies[reply] == nil {
                guard lock.wait(until: deadline) else {
                    throw ClusterSetupFailure("the other Mac did not answer within \(Int(seconds)) s")
                }
            }
            return replies[reply]!
        }

        func close() { client.stop() }
    }

    /// Keep the socket reason alongside the protocol refusal: a detached process denied Local Network
    /// otherwise reports only `connectFailed`, indistinguishable from a cable or listener problem.
    static func connectionFailure(refusal: ClusterLinkControlRefusal?, dial: String?) -> String {
        let reason = refusal.map { "refused (\($0))" } ?? "no answer"
        guard refusal == nil || refusal == .connectFailed, let dial else { return reason }
        let detail = reason + " (\(dial))"
        guard dial == "unreachable" else { return detail }
        return detail + "; check Darkbloom's Local Network access in System Settings on this Mac. "
            + "A development service detached from Terminal or SSH can lose that session's access; "
            + "use a signed Darkbloom.app for the background service. Also check the cable route."
    }

    private final class WeakSessionBox: @unchecked Sendable { weak var session: Session? }

    /// Finds the other Mac's open wizard on the cable (its discovery answer),
    /// connects with the pairing's key, and returns what it reports. The
    /// address it answered from is returned for the delivery.
    public static func ask(pairing: Pairing, selection: ClusterLinkInterfaceSelection, seconds: Double,
                           port: UInt16 = ClusterSetupLinkExchange.port, policy: ClusterLinkInterfacePolicy = .thunderboltOnly)
        throws -> (answer: ClusterSetupLinkAnswer, peerAddress: ClusterLinkIPv4Address) {
        try oneAtATime(seconds: seconds) { try askNow(pairing: pairing, selection: selection, seconds: seconds, port: port, policy: policy) }
    }

    private static func askNow(pairing: Pairing, selection: ClusterLinkInterfaceSelection, seconds: Double, port: UInt16,
                               policy: ClusterLinkInterfacePolicy) throws -> (answer: ClusterSetupLinkAnswer, peerAddress: ClusterLinkIPv4Address) {
        let found = ClusterLinkPairingDiscovery.find(selection: selection, port: port, seconds: min(seconds, 8))
        guard let peer = found.first else {
            throw ClusterSetupFailure("the other Mac's wizard did not answer on the cable: open `darkbloom cluster` on the other Mac too")
        }
        let session = try Session(pairing: pairing, selection: selection, peerAddress: peer.address, port: port, policy: policy)
        defer { session.close() }
        let data = try session.request(tag: askTag, Data("report".utf8), reply: answerTag, seconds: seconds)
        if let text = String(data: data.prefix(6), encoding: .utf8), text == "error:" {
            throw ClusterSetupFailure("the other Mac could not report: " + (String(data: data.dropFirst(6), encoding: .utf8) ?? ""))
        }
        guard data.count <= maximumBytes else { throw ClusterSetupFailure("the other Mac's answer is too large") }
        let answer = try JSONDecoder().decode(ClusterSetupLinkAnswer.self, from: data)
        guard answer.report.schema == ClusterSetupReport.schemaName else {
            throw ClusterSetupFailure("the other Mac answered with a report this build does not read")
        }
        try answer.facts.validate()
        guard answer.facts.memberID == pairing.peerMemberID else {
            throw ClusterSetupFailure("the Mac that answered is not the one this Mac paired with")
        }
        return (answer, peer.address)
    }

    /// Sends one command to the other Mac's cluster service and returns its answer.
    public static func command(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address?,
                               body: Data, seconds: Double, port: UInt16 = ClusterSetupLinkExchange.port,
                               policy: ClusterLinkInterfacePolicy = .thunderboltOnly) throws -> (reply: Data, peerAddress: ClusterLinkIPv4Address) {
        try oneAtATime(seconds: seconds) {
            try commandNow(pairing: pairing, selection: selection, peerAddress: peerAddress, body: body, seconds: seconds, port: port, policy: policy)
        }
    }

    /// One lease (or hand-over) to the other Mac's control listener: its own port, edge epoch and request lock.
    public static func lease(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address?,
                             body: Data, seconds: Double, policy: ClusterLinkInterfacePolicy = .thunderboltOnly)
        throws -> (reply: Data, peerAddress: ClusterLinkIPv4Address) {
        try oneAtATime(seconds: seconds, lockName: controlLockName) {
            try commandNow(pairing: pairing, selection: selection, peerAddress: peerAddress, body: body, seconds: seconds,
                port: controlPort, policy: policy, label: controlLabel)
        }
    }

    private static func commandNow(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address?,
                                   body: Data, seconds: Double, port: UInt16, policy: ClusterLinkInterfacePolicy,
                                   label: String = exchangeLabel) throws -> (reply: Data, peerAddress: ClusterLinkIPv4Address) {
        var address = peerAddress
        if address == nil { address = ClusterLinkPairingDiscovery.find(selection: selection, port: port, seconds: min(seconds, 8)).first?.address }
        guard let address else {
            throw ClusterSetupFailure("the other Mac's cluster service did not answer on the cable")
        }
        let session = try Session(pairing: pairing, selection: selection, peerAddress: address, port: port, policy: policy, label: label)
        defer { session.close() }
        let data = try session.request(tag: commandTag, body, reply: commandReplyTag, seconds: seconds)
        if data.starts(with: Data("ok:".utf8)) { return (data.dropFirst(3), address) }
        let text = String(decoding: data, as: UTF8.self)
        throw ClusterSetupFailure("the other Mac refused: " + String(text.dropFirst(text.hasPrefix("error:") ? 6 : 0)))
    }

    /// Hands the other Mac its setup for its inbox. Returns the digest it says saving would give.
    public static func deliver(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address?,
                               delivery: Data, seconds: Double, port: UInt16 = ClusterSetupLinkExchange.port,
                               policy: ClusterLinkInterfacePolicy = .thunderboltOnly) throws -> String {
        try oneAtATime(seconds: seconds) {
            try deliverNow(pairing: pairing, selection: selection, peerAddress: peerAddress, delivery: delivery, seconds: seconds, port: port, policy: policy)
        }
    }

    private static func deliverNow(pairing: Pairing, selection: ClusterLinkInterfaceSelection, peerAddress: ClusterLinkIPv4Address?,
                                   delivery: Data, seconds: Double, port: UInt16, policy: ClusterLinkInterfacePolicy) throws -> String {
        var address = peerAddress
        if address == nil { address = ClusterLinkPairingDiscovery.find(selection: selection, port: port, seconds: min(seconds, 8)).first?.address }
        guard let address else {
            throw ClusterSetupFailure("the other Mac's wizard did not answer on the cable: open `darkbloom cluster` on the other Mac too")
        }
        let session = try Session(pairing: pairing, selection: selection, peerAddress: address, port: port, policy: policy)
        defer { session.close() }
        let data = try session.request(tag: deliverTag, delivery, reply: receiptTag, seconds: seconds)
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("ok:") { return String(text.dropFirst(3)) }
        throw ClusterSetupFailure("the other Mac did not take its setup: " + String(text.dropFirst(text.hasPrefix("error:") ? 6 : 0)))
    }
}
