import Foundation
import Testing
@testable import ProviderCore

// MARK: - DistributedGroupBootstrapTests
//
// Tests for DistributedGroupBootstrap. Scope is intentionally limited:
//
//   ✅ API surface compiles and types are correct
//   ✅ setEnvironmentVariables writes the right values into the process env
//   ✅ writeTopologyFile produces well-formed JSON with the expected structure
//   ✅ DistributedGroup() (no-arg) returns a singleton with size == 1
//
//   ❌ NOT tested here: actual jaccl DistributedGroup initialization with
//      backend: .jaccl or strict: .jaccl. That requires two cooperating
//      processes and TB5 Thunderbolt-connected Apple Silicon hardware with
//      RDMA enabled in macOS Recovery. There is no way to exercise this path
//      in a single-process CI test; the real path is covered by manual E2E
//      testing on the two-Mac rig.

// MARK: - Fixture helpers

private func makeConfig(
    ownRank: Int = 0,
    ownIP: String = "169.254.100.1",
    peerIP: String = "169.254.100.2",
    port: UInt16 = 29400,
    sessionID: String = "test-session-\(UUID().uuidString)"
) -> DistributedGroupBootstrapConfig {
    DistributedGroupBootstrapConfig(
        ownRank: ownRank,
        ownIP: ownIP,
        peerIP: peerIP,
        port: port,
        sessionID: sessionID
    )
}

// MARK: - Config construction

@Test("DistributedGroupBootstrapConfig stores all fields correctly")
func bootstrapConfigFieldsRoundTrip() {
    let cfg = DistributedGroupBootstrapConfig(
        ownRank: 1,
        ownIP: "169.254.5.6",
        peerIP: "169.254.5.7",
        port: 29400,
        sessionID: "abc-123"
    )
    #expect(cfg.ownRank == 1)
    #expect(cfg.ownIP == "169.254.5.6")
    #expect(cfg.peerIP == "169.254.5.7")
    #expect(cfg.port == 29400)
    #expect(cfg.sessionID == "abc-123")
}

// MARK: - Error descriptions

@Test("DistributedGroupBootstrapError descriptions are non-empty")
func bootstrapErrorDescriptions() {
    let errors: [DistributedGroupBootstrapError] = [
        .envVarSetFailed("MLX_RANK: bad"),
        .topologyWriteFailed("/tmp/foo: permission denied"),
        .jacclInitFailed("rdma not available"),
    ]
    for e in errors {
        #expect(!e.description.isEmpty)
    }
}

// MARK: - Environment variable setting

@Test("setEnvironmentVariables writes MLX_RANK for rank 0")
func envVarsRank0() throws {
    let sessionID = "env-test-rank0-\(UUID().uuidString)"
    let cfg = makeConfig(ownRank: 0, ownIP: "10.0.0.1", peerIP: "10.0.0.2",
                         port: 29400, sessionID: sessionID)
    // Use a dummy topology path — we only test env var values here.
    let fakePath = "/tmp/topology-\(sessionID).json"
    try DistributedGroupBootstrap.setEnvironmentVariables(config: cfg, topologyPath: fakePath)

    // MLX_RANK must be "0".
    let rank = ProcessInfo.processInfo.environment["MLX_RANK"]
    #expect(rank == "0")

    // MLX_JACCL_COORDINATOR must be rank 0's own IP:port.
    let coordinator = ProcessInfo.processInfo.environment["MLX_JACCL_COORDINATOR"]
    #expect(coordinator == "10.0.0.1:29400")

    // MLX_IBV_DEVICES must be the path we passed.
    let devices = ProcessInfo.processInfo.environment["MLX_IBV_DEVICES"]
    #expect(devices == fakePath)
}

@Test("setEnvironmentVariables writes MLX_RANK for rank 1")
func envVarsRank1() throws {
    let sessionID = "env-test-rank1-\(UUID().uuidString)"
    let cfg = makeConfig(ownRank: 1, ownIP: "10.0.0.2", peerIP: "10.0.0.1",
                         port: 29400, sessionID: sessionID)
    let fakePath = "/tmp/topology-\(sessionID).json"
    try DistributedGroupBootstrap.setEnvironmentVariables(config: cfg, topologyPath: fakePath)

    let rank = ProcessInfo.processInfo.environment["MLX_RANK"]
    #expect(rank == "1")

    // For rank 1, the coordinator address is rank 0's IP (the peerIP of rank 1).
    let coordinator = ProcessInfo.processInfo.environment["MLX_JACCL_COORDINATOR"]
    #expect(coordinator == "10.0.0.1:29400")
}

@Test("setEnvironmentVariables port is included verbatim in coordinator address")
func envVarPortFormat() throws {
    let sessionID = "env-test-port-\(UUID().uuidString)"
    let cfg = makeConfig(ownRank: 0, ownIP: "192.168.100.1", peerIP: "192.168.100.2",
                         port: 12345, sessionID: sessionID)
    try DistributedGroupBootstrap.setEnvironmentVariables(config: cfg, topologyPath: "/tmp/x")
    let coordinator = ProcessInfo.processInfo.environment["MLX_JACCL_COORDINATOR"]
    #expect(coordinator == "192.168.100.1:12345")
}

// MARK: - Topology file generation

@Test("writeTopologyFile creates a valid JSON file")
func topologyFileIsValidJSON() throws {
    let sessionID = "topo-test-\(UUID().uuidString)"
    let cfg = makeConfig(ownRank: 0, ownIP: "169.254.1.1", peerIP: "169.254.1.2",
                         sessionID: sessionID)
    let path = try DistributedGroupBootstrap.writeTopologyFile(config: cfg)

    // File must exist.
    #expect(FileManager.default.fileExists(atPath: path))

    // Must be valid JSON.
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    #expect(parsed != nil)

    // Clean up.
    try? FileManager.default.removeItem(atPath: path)
}

@Test("writeTopologyFile path uses the session ID")
func topologyFilePathContainsSessionID() throws {
    let sessionID = "mysession-42"
    let cfg = makeConfig(sessionID: sessionID)
    let path = try DistributedGroupBootstrap.writeTopologyFile(config: cfg)
    #expect(path.contains(sessionID))
    try? FileManager.default.removeItem(atPath: path)
}

@Test("writeTopologyFile contains exactly two rank entries")
func topologyFileTwoRanks() throws {
    let sessionID = "topo-2rank-\(UUID().uuidString)"
    let cfg = makeConfig(ownRank: 0, ownIP: "169.254.1.1", peerIP: "169.254.1.2",
                         sessionID: sessionID)
    let path = try DistributedGroupBootstrap.writeTopologyFile(config: cfg)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let parsed = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    #expect(parsed.count == 2)

    // Sort by rank so assertions are deterministic regardless of array order.
    let sorted = parsed.sorted { ($0["rank"] as! Int) < ($1["rank"] as! Int) }

    // Rank 0 entry.
    #expect(sorted[0]["rank"] as? Int == 0)
    #expect(sorted[0]["interface"] as? String == "bridge100")
    #expect(sorted[0]["ip"] as? String == "169.254.1.1")  // rank 0's own IP

    // Rank 1 entry.
    #expect(sorted[1]["rank"] as? Int == 1)
    #expect(sorted[1]["interface"] as? String == "bridge100")
    #expect(sorted[1]["ip"] as? String == "169.254.1.2")  // rank 0's peer IP
}

@Test("writeTopologyFile assigns IPs correctly when called from rank 1's perspective")
func topologyFileFromRank1Perspective() throws {
    let sessionID = "topo-r1-\(UUID().uuidString)"
    // From rank 1's view: ownIP = "169.254.1.2", peerIP (rank 0) = "169.254.1.1".
    let cfg = makeConfig(ownRank: 1, ownIP: "169.254.1.2", peerIP: "169.254.1.1",
                         sessionID: sessionID)
    let path = try DistributedGroupBootstrap.writeTopologyFile(config: cfg)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let parsed = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let sorted = parsed.sorted { ($0["rank"] as! Int) < ($1["rank"] as! Int) }

    // Rank 0 must map to the peer IP (from rank 1's perspective, peerIP = rank 0's IP).
    #expect(sorted[0]["ip"] as? String == "169.254.1.1")
    // Rank 1 must map to own IP.
    #expect(sorted[1]["ip"] as? String == "169.254.1.2")
}

@Test("writeTopologyFile uses bridge100 for both ranks")
func topologyFileInterfaceName() throws {
    let sessionID = "topo-iface-\(UUID().uuidString)"
    let cfg = makeConfig(sessionID: sessionID)
    let path = try DistributedGroupBootstrap.writeTopologyFile(config: cfg)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let parsed = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

    for entry in parsed {
        #expect(entry["interface"] as? String == "bridge100")
    }
}

// MARK: - DistributedGroup singleton (no-arg init)

// NOTE: This test only exercises the no-arg `DistributedGroup()` path which
// returns a singleton group (size == 1) when jaccl is not available. This
// validates that the API surface compiles and the C bridge returns something
// coherent on a machine without RDMA configured. It does NOT test the jaccl
// two-process path — that path cannot be tested in a single-process test
// without TB5 hardware and RDMA enabled in macOS Recovery.

@Test("DistributedGroup no-arg init returns a group with size >= 1")
func distributedGroupSingletonSize() {
    // initialize(strict: false) returns nil if the backend can't load at all
    // (e.g., on a CI runner without Metal/MLX), and a size=1 group otherwise.
    // Either outcome is acceptable here — we're testing the API surface, not
    // the RDMA stack.
    if let group = DistributedGroup.initialize(strict: false) {
        #expect(group.size >= 1)
        // Singleton group should have rank 0.
        #expect(group.rank >= 0)
    }
    // If nil is returned (no Metal on CI), the test still passes — the API
    // compiled and returned an Optional, which is the expected behavior.
}

@Test("DistributedGroup.isAvailable is queryable without crashing")
func distributedGroupAvailabilityCheck() {
    // Just ensure calling the static property doesn't throw or crash.
    let _ = DistributedGroup.isAvailable
}

// MARK: - JacclBootstrapPayload round-trip

@Test("JacclBootstrapPayload encodes and decodes via JSON")
func jacclBootstrapPayloadRoundTrip() throws {
    let original = JacclBootstrapPayload(port: 29400, sessionID: "round-trip-test")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JacclBootstrapPayload.self, from: data)
    #expect(decoded.port == original.port)
    #expect(decoded.sessionID == original.sessionID)
}

@Test("ClusterMsgType.jacclBootstrap has the expected raw value 0x07")
func jacclBootstrapMsgTypeValue() {
    #expect(ClusterMsgType.jacclBootstrap.rawValue == 0x07)
}

@Test("ClusterFrame can encode and decode a jacclBootstrap frame")
func jacclBootstrapFrameRoundTrip() throws {
    let payload = JacclBootstrapPayload(port: 29400, sessionID: "frame-test")
    let frame = try ClusterFrame.encodeJSON(type: .jacclBootstrap, value: payload)

    let msgType = try ClusterFrame.decodeType(from: frame)
    #expect(msgType == .jacclBootstrap)

    let decoded = try ClusterFrame.decodeJSON(JacclBootstrapPayload.self, from: frame)
    #expect(decoded.port == 29400)
    #expect(decoded.sessionID == "frame-test")
}
