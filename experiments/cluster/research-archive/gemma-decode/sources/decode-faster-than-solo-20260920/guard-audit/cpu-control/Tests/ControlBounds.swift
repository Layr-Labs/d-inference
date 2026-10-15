import Cmlx
import Foundation

// Compile with the actual proposed CollectivePointToPoint.swift, its actual
// CollectivePointToPointShape.swift dependency and ClusterRuntimeError.swift.
// This does not initialize a collective or construct/evaluate an MLX graph.
@main enum ControlBounds {
    static func main() throws {
        let cases = [(0, 1), (1, 0), (1, -1), (2, 1), (1, 65_537), (65_537, 65_536)]
        var observations = 0
        let invalidGroup = mlx_distributed_group(ctx: nil)
        for (count, bound) in cases {
            func refuses(_ body: () throws -> Void) throws {
                do { try body() }
                catch let error as ProbeError {
                    guard error.description == "CPU control bytes exceed their explicit bound" else { throw error }
                    return
                }
                throw ProbeError("Invalid control bound was admitted")
            }
            try refuses {
                try CollectivePointToPoint.sendControl(Data(repeating: 0, count: count),
                    peer: 1, group: invalidGroup, rank: 0, size: 2,
                    maximumBytes: bound, check: { observations += 1 })
            }
            try refuses {
                _ = try CollectivePointToPoint.receiveControl(byteCount: count,
                    peer: 1, group: invalidGroup, rank: 0, size: 2,
                    maximumBytes: bound, check: { observations += 1 })
            }
        }
        guard observations == 0 else { throw ProbeError("Invalid size entered the native operation") }
        print("PASS actual-control-bounds 12 refusals; no collective or MLX graph")
    }
}
