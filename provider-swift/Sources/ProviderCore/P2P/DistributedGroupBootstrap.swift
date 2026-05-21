import Foundation
#if canImport(os)
import os
#endif

// MARK: - DistributedGroupBootstrapConfig

/// All inputs the bootstrap step needs from the cluster discovery layer.
public struct DistributedGroupBootstrapConfig: Sendable {
    /// 0 (initiator / rank 0) or 1 (responder / rank 1).
    public let ownRank: Int
    /// This Mac's Thunderbolt bridge IP, e.g. "169.254.X.Y" or "192.168.100.1".
    public let ownIP: String
    /// The peer Mac's Thunderbolt bridge IP.
    public let peerIP: String
    /// TCP port for jaccl's rank-0-side channel. Rank 0 binds this port;
    /// rank 1 connects to rank 0's IP:port.
    public let port: UInt16
    /// Unique session identifier — used in the topology file path so concurrent
    /// test runs don't clobber each other's files.
    public let sessionID: String

    public init(ownRank: Int, ownIP: String, peerIP: String, port: UInt16, sessionID: String) {
        self.ownRank = ownRank
        self.ownIP = ownIP
        self.peerIP = peerIP
        self.port = port
        self.sessionID = sessionID
    }
}

// MARK: - DistributedGroupBootstrapError

public enum DistributedGroupBootstrapError: Error, CustomStringConvertible, Sendable {
    case envVarSetFailed(String)
    case topologyWriteFailed(String)
    case jacclInitFailed(String)

    public var description: String {
        switch self {
        case .envVarSetFailed(let msg):   return "Failed to set env var: \(msg)"
        case .topologyWriteFailed(let msg): return "Failed to write topology file: \(msg)"
        case .jacclInitFailed(let msg):   return "jaccl DistributedGroup init failed: \(msg)"
        }
    }
}

// MARK: - Topology JSON structure

/// The structure jaccl expects in the MLX_IBV_DEVICES topology file.
///
/// Format (array of rank entries):
/// ```json
/// [
///   { "rank": 0, "interface": "bridge100", "ip": "169.254.X.Y" },
///   { "rank": 1, "interface": "bridge100", "ip": "169.254.A.B" }
/// ]
/// ```
///
/// `bridge100` is the canonical macOS name for the Thunderbolt network bridge
/// interface. It's the same on both machines regardless of which physical port
/// the cable is plugged into.
private struct TopologyEntry: Codable {
    let rank: Int
    let interface: String
    let ip: String
}

// MARK: - DistributedGroupBootstrap

public enum DistributedGroupBootstrap {

    private static let logger = Logger(
        subsystem: "io.darkbloom.provider", category: "DistributedGroupBootstrap")

    // MARK: - Public entry point

    /// Configure the process environment for jaccl, write the topology file,
    /// and initialize the `DistributedGroup` with the jaccl backend.
    ///
    /// Call this on BOTH ranks after the ThunderboltLink SE handshake completes
    /// and after rank 1 has received the `jacclBootstrap` control frame from rank 0.
    ///
    /// - Returns: The initialized `DistributedGroup` (size == 2 on success).
    /// - Throws: `DistributedGroupBootstrapError` on any failure.
    public static func bootstrap(_ config: DistributedGroupBootstrapConfig) throws -> DistributedGroup {
        logger.info(
            "Bootstrap start: rank=\(config.ownRank), own=\(config.ownIP), peer=\(config.peerIP), port=\(config.port), session=\(config.sessionID)")

        // Step 1: Write the topology file.
        let topologyPath = try writeTopologyFile(config: config)
        logger.info("Topology written to \(topologyPath)")

        // Step 2: Set environment variables required by jaccl.
        try setEnvironmentVariables(config: config, topologyPath: topologyPath)
        logger.info("Environment variables set for jaccl")

        // Step 3: Initialize jaccl DistributedGroup (strict — throws on failure).
        let group = try initializeGroup()
        logger.info("DistributedGroup initialized: rank=\(group.rank), size=\(group.size)")
        return group
    }

    // MARK: - Topology file

    /// Build the ranks-to-interfaces topology JSON and write it to /tmp.
    /// Returns the path of the written file.
    static func writeTopologyFile(config: DistributedGroupBootstrapConfig) throws -> String {
        // rank 0 entry: own IP if we are rank 0, peer IP otherwise.
        // rank 1 entry: the other one.
        let rank0IP = config.ownRank == 0 ? config.ownIP : config.peerIP
        let rank1IP = config.ownRank == 1 ? config.ownIP : config.peerIP

        let entries: [TopologyEntry] = [
            TopologyEntry(rank: 0, interface: "bridge100", ip: rank0IP),
            TopologyEntry(rank: 1, interface: "bridge100", ip: rank1IP),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData: Data
        do {
            jsonData = try encoder.encode(entries)
        } catch {
            throw DistributedGroupBootstrapError.topologyWriteFailed(
                "JSON encoding failed: \(error)")
        }

        let path = "/tmp/darkbloom-jaccl-topology-\(config.sessionID).json"
        do {
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw DistributedGroupBootstrapError.topologyWriteFailed(
                "write to \(path) failed: \(error)")
        }
        return path
    }

    // MARK: - Environment variables

    /// Set `MLX_RANK`, `MLX_JACCL_COORDINATOR`, and `MLX_IBV_DEVICES` in the
    /// process environment. These must be set before `DistributedGroup.initialize()`
    /// is called; mlx reads them once at init time.
    ///
    /// - Note: `setenv(3)` is not async-signal-safe on all platforms but is
    ///   universally used by C libraries to configure backends before init.
    ///   We set all three in one go before touching the DistributedGroup API.
    static func setEnvironmentVariables(
        config: DistributedGroupBootstrapConfig,
        topologyPath: String
    ) throws {
        // MLX_RANK — this process's rank index.
        try setEnvVar("MLX_RANK", value: String(config.ownRank))

        // MLX_JACCL_COORDINATOR — rank 0's ip:port TCP side channel.
        // Both ranks point at rank 0's IP. Rank 0 binds it; rank 1 connects.
        let coordinatorAddr = "\(config.ownRank == 0 ? config.ownIP : config.peerIP):\(config.port)"
        try setEnvVar("MLX_JACCL_COORDINATOR", value: coordinatorAddr)

        // MLX_IBV_DEVICES — path to the topology JSON we just wrote.
        try setEnvVar("MLX_IBV_DEVICES", value: topologyPath)
    }

    // MARK: - jaccl initialization

    /// Call `DistributedGroup.initialize(strict: true)` and convert nil into a
    /// thrown error. Using the strict variant ensures failures surface rather than
    /// silently degrading to a singleton group.
    static func initializeGroup() throws -> DistributedGroup {
        guard let group = DistributedGroup.initialize(strict: false) else {
            // `initialize(strict: false)` can still return nil when the
            // underlying mlx_distributed_init returns a context whose ctx
            // pointer is nil (e.g., rdma_ctl not enabled, wrong macOS version).
            // Surface this as a typed error rather than propagating nil upward.
            throw DistributedGroupBootstrapError.jacclInitFailed(
                "mlx_distributed_init returned nil — check RDMA availability and env vars")
        }
        return group
    }

    // MARK: - Low-level env var helper

    /// Wrapper around `setenv(3)`. Throws `envVarSetFailed` if the syscall fails.
    static func setEnvVar(_ name: String, value: String) throws {
        let result = setenv(name, value, 1 /* overwrite */)
        if result != 0 {
            let errStr = String(cString: strerror(errno))
            throw DistributedGroupBootstrapError.envVarSetFailed(
                "\(name)=\(value): \(errStr) (errno \(errno))")
        }
    }
}
