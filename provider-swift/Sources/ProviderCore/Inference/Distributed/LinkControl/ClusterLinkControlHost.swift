import DarkbloomClusterRemote
import Foundation

/// Hosts the link control listener (PROD-PLAN S06) inside the provider
/// process. macOS ties the firewall decision and the Local Network permission
/// to the signed binary that listens; keeping the listener here means the
/// owner approves the provider once, never a per-build worker or a helper,
/// and the approval survives restarts and reboots.
///
/// Not wired to coordinator serving yet (S08-S10 build the follower endpoint
/// and the pair slot on top of it). Today it is started by the qualification
/// command and by tests.
public final class ClusterLinkControlHost: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case stopped
        case listening(interface: String, kind: ClusterLinkInterfaceKind, port: UInt16)
        /// The interface or address was refused (for example Wi-Fi); names only.
        case refused(String)
    }

    private let lock = NSLock()
    private let inspector: any ClusterLinkInterfaceInspecting
    private var listener: ClusterLinkControlListener?
    private var current: State = .stopped

    public init(inspector: any ClusterLinkInterfaceInspecting = ClusterLinkSystemInterfaceInspector()) {
        self.inspector = inspector
    }

    deinit { stop() }

    public var state: State { lock.withLock { current } }

    /// Starts one listener for these edges; a running one is stopped first.
    /// Refusals (Wi-Fi, a non-Thunderbolt port, an address not on the port, a
    /// peer off the link) leave the host stopped with the reason recorded.
    @discardableResult
    public func start(_ configuration: ClusterLinkControlListener.Configuration,
                      handler: @escaping ClusterLinkControlEventHandler) throws -> ClusterLinkControlListener {
        stop()
        let created = try ClusterLinkControlListener(configuration: configuration, inspector: inspector, handler: handler)
        do {
            let port = try created.start()
            let kind = created.selection?.kind ?? .other
            lock.withLock {
                listener = created
                current = .listening(interface: configuration.interface, kind: kind, port: port)
            }
            return created
        } catch {
            let reason = (error as? ClusterLinkInterfaceRefusal).map { String(describing: $0) } ?? "bindFailed"
            lock.withLock { current = .refused(reason) }
            created.stop()
            throw error
        }
    }

    public func stop() {
        let running: ClusterLinkControlListener? = lock.withLock {
            defer { listener = nil; if case .listening = current { current = .stopped } }
            return listener
        }
        running?.stop()
    }

    public func peer(for edgeID: UUID) -> ClusterLinkControlPeer? {
        lock.withLock { listener }?.peer(for: edgeID)
    }

    /// The interface to listen on for a link's RDMA device (`rdma_en7` ->
    /// `en7`): the port itself when it carries IPv4 (link setup v2), else the
    /// Thunderbolt Bridge that contains it (today's Internet Sharing setup).
    /// With `reaching` (the leader's link address), the port or bridge that
    /// holds an address on that subnet: a port can carry only a self-assigned
    /// link-local address while its bridge holds the leader's subnet.
    public static func listenInterface(forDevice device: String, reaching leader: ClusterLinkIPv4Address? = nil) -> String? {
        guard device.hasPrefix("rdma_") else { return nil }
        let port = String(device.dropFirst("rdma_".count))
        guard let leader else { return ClusterLinkSystemInterfaceInspector.carrierInterface(forPort: port) }
        return ClusterLinkSystemInterfaceInspector.carrierInterface(forPort: port, reaching: leader)
    }
}

/// Inputs of the hidden `cluster link-channel` qualification command, as
/// plain values so the command target needs only ProviderCore.
public struct ClusterLinkChannelQualificationRequest: Sendable {
    public var interface: String?
    public var device: String?
    public var localAddress: String?
    public var peerAddress: String?
    public var port: Int = Int(ClusterLinkControlListener.defaultPort)
    public var epoch: String
    public var edge: String
    public var loopbackForTests = false
    public var heartbeatMilliseconds: Int?
    public var silenceMilliseconds: Int?
    public var seconds: Double = 600
    public var pings = 2000
    public var spacedPings = 300
    public var gapsMicroseconds: [UInt32] = [1000, 10_000]
    public var typedEchoes = 500
    public var bulkFrames = 256
    public var bulkFrameBytes = 1 << 20
    public var reverseBulk = true
    public var resumeSeconds: Double = 0
    public var connectSeconds: Double = 20

    public init(epoch: String, edge: String) { self.epoch = epoch; self.edge = edge }
}

public struct ClusterLinkChannelQualificationError: Error, CustomStringConvertible {
    public let description: String
}

extension ClusterLinkControlHost {
    /// Listens inside this process until standard input closes; the secret is
    /// the first line of standard input. Returns the summary as JSON.
    public static func qualificationListen(_ request: ClusterLinkChannelQualificationRequest,
                                           output: @escaping @Sendable (String) -> Void) throws -> String {
        let options = try qualificationOptions(request)
        let secret = try ClusterLinkControlQualification.readSecret()
        let host = ClusterLinkControlHost()
        defer { host.stop() }
        let summary = try ClusterLinkControlQualification.listen(options: options, secret: secret, output: output) {
            configuration, handler in try host.start(configuration, handler: handler)
        }
        return json(summary)
    }

    /// Connects and measures; `measured` is false when no session came up.
    public static func qualificationProbe(_ request: ClusterLinkChannelQualificationRequest,
                                          output: @escaping @Sendable (String) -> Void) throws -> (json: String, measured: Bool) {
        let options = try qualificationOptions(request)
        let secret = try ClusterLinkControlQualification.readSecret()
        let summary = try ClusterLinkControlQualification.probe(options: options, secret: secret, output: output)
        return (json(summary), summary.report != nil)
    }

    static func qualificationOptions(_ request: ClusterLinkChannelQualificationRequest) throws -> ClusterLinkControlQualification.Options {
        guard let epoch = UUID(uuidString: request.epoch), let edge = UUID(uuidString: request.edge) else {
            throw ClusterLinkChannelQualificationError(description: "--epoch and --edge must be UUIDs.")
        }
        guard (0...65_535).contains(request.port) else {
            throw ClusterLinkChannelQualificationError(description: "--port is out of range.")
        }
        let interface: String
        if request.loopbackForTests { interface = "lo0" } else if let named = request.interface { interface = named } else if
            let device = request.device, let carrier = listenInterface(forDevice: device) { interface = carrier } else {
            throw ClusterLinkChannelQualificationError(description: "Give --interface, or a --device whose port or bridge carries IPv4.")
        }
        func address(_ text: String?, _ name: String) throws -> ClusterLinkIPv4Address? {
            guard let text else { return nil }
            guard let value = ClusterLinkIPv4Address(text) else {
                throw ClusterLinkChannelQualificationError(description: "--\(name) must be an IPv4 address.")
            }
            return value
        }
        var options = ClusterLinkControlQualification.Options(interface: interface,
            localAddress: try address(request.localAddress, "local-address"),
            peerAddress: try address(request.peerAddress, "peer-address"), port: UInt16(request.port),
            policy: request.loopbackForTests ? .loopbackForTests : .thunderboltOnly, epoch: epoch, edgeID: edge)
        if let value = request.heartbeatMilliseconds { options.limits.heartbeatInterval = .milliseconds(value) }
        if let value = request.silenceMilliseconds { options.limits.silenceTimeout = .milliseconds(value) }
        options.seconds = request.seconds
        options.probe.pings = request.pings; options.probe.spacedPings = request.spacedPings
        options.probe.pingGapsMicroseconds = request.gapsMicroseconds; options.probe.typedEchoes = request.typedEchoes
        options.probe.bulkFrames = request.bulkFrames; options.probe.bulkFrameBytes = request.bulkFrameBytes
        options.probe.reverseBulk = request.reverseBulk
        options.resumeSeconds = request.resumeSeconds; options.connectSeconds = request.connectSeconds
        return options
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
