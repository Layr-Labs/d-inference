import Foundation
import MLX

/// Shared fixed-shape completed exchange. It owns no request state or clock.
/// The material factory runs at the former request digest-construction point.
func requireQwenLongPrefillReadinessDigest(collective: Collective,
    material: () -> QwenLongPrefillReadinessMaterial, disagreementMessage: String,
    recordScope: (() throws -> CollectiveOperationScope)? = nil,
    check: () throws -> Void
) throws -> String {
    guard collective.size == 2, (0..<2).contains(collective.rank) else {
        throw ProbeError("Long prefill readiness requires exactly two admitted ranks")
    }
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let endpoint = try collective.scoped {
                guard let recordScope else { throw ProbeError("Protected readiness has no explicit operation scope") }
                return try recordScope()
            }
            let digest = material().digest
            let values = digest.utf8.map(Int32.init)
            func send() throws {
                let array = MLXArray(values)
                try checked()
                _ = try endpoint.sendCompleted(array, to: 1 - collective.rank,
                    maximumBytes: 256, check: checked)
            }
            func receive() throws -> [Int32] {
                let actual = try endpoint.receiveCompleted(shape: [64], dtype: .int32,
                    from: 1 - collective.rank, maximumBytes: 256, check: checked).asArray(Int32.self)
                try checked()
                return actual
            }
            // Both ranks publish their digest before either rejects its peer's value.
            // Completed send is not a peer-consumption acknowledgment.
            let actual: [Int32]
            if collective.rank == 0 { try send(); actual = try receive() }
            else { actual = try receive(); try send() }
            try checked()
            guard actual == values else {
                throw ProbeError(disagreementMessage)
            }
            return digest
        }
    } catch { collective.invalidateProtection(); throw error }
}
