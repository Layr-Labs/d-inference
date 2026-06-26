/// MLXRingEnvironment -- materialize a `ClusterPlan` into the exact environment
/// MLX's ring backend reads at `mlx_distributed_init(backend: "ring")`.
///
/// Verified against the linked MLX C++ (mlx/distributed/ring/ring.cpp): the ring
/// backend reads `MLX_HOSTFILE` (a JSON file: a rank-ordered list, each entry a
/// list of "ip:port" addresses) and `MLX_RANK`. This writes that hostfile and
/// returns the env vars to set before initializing the group.
///
/// Member addresses in `[cluster]` are "host" or "host:port"; we default the
/// port to a fixed ring base port when absent. Pure (writes one file) and
/// independently testable: the JSON shape is asserted in tests.

import Foundation

public enum MLXRingEnvironmentError: Error, Sendable {
    case writeFailed(path: String)
    case encodeFailed
}

public enum MLXRingEnvironment {
    /// Default TCP port for the ring transport when a member address omits one.
    public static let defaultRingPort: UInt16 = 5680

    /// Build the rank-ordered hostfile JSON (`[["ip:port"], ...]`) from a plan.
    public static func hostfileJSON(_ plan: ClusterPlan) throws -> Data {
        let nodes: [[String]] = plan.members.map { member in
            [normalizedAddress(member.address)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted]) else {
            throw MLXRingEnvironmentError.encodeFailed
        }
        return data
    }

    /// Ensure `address` has a port; append the default ring port if not.
    public static func normalizedAddress(_ address: String) -> String {
        // IPv6 literals contain ':' — only append a port when there's no
        // host:port form already (heuristic: a single trailing ':port').
        if address.contains("]:") { return address }            // [v6]:port
        if address.hasPrefix("[") { return "\(address):\(defaultRingPort)" } // [v6]
        let parts = address.split(separator: ":")
        if parts.count == 2, UInt16(parts[1]) != nil { return address } // host:port
        return "\(address):\(defaultRingPort)"
    }

    /// Write the hostfile to `directory` and return the env vars MLX needs.
    /// The provider start path sets these (via `setenv`) before
    /// `MLXDistributedGroup.initialize(.ring)`.
    @discardableResult
    public static func materialize(_ plan: ClusterPlan, directory: URL) throws -> [String: String] {
        let json = try hostfileJSON(plan)
        let path = directory.appendingPathComponent("mlx-hostfile-\(plan.clusterId).json")
        do {
            try json.write(to: path, options: .atomic)
        } catch {
            throw MLXRingEnvironmentError.writeFailed(path: path.path)
        }
        return [
            "MLX_HOSTFILE": path.path,
            "MLX_RANK": String(plan.rank),
        ]
    }
}
