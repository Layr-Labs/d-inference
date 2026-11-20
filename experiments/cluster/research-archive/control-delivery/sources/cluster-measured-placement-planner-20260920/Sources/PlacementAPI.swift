import Foundation

/// A bounded JSON facade keeps this Foundation-only calculation reusable from
/// CLI, configuration tooling and a future product adapter. It performs no IO,
/// allocation reservation, model loading, authority checks or plan activation.
public enum MeasuredPlacementAPI {
    public static func predict(_ input: Data) throws -> Data {
        guard input.count <= 16_777_216 else { throw PlacementError.invalid("input exceeds 16 MiB") }
        let envelope = try JSONDecoder().decode(PlacementEnvelope.self, from: input)
        guard envelope.schema == "measured_two_node_placement_v1" else { throw PlacementError.invalid("schema") }
        let report = try MeasuredPlacementPlanner.plan(envelope.request, measurements: envelope.measurements,
                                                      objective: envelope.objective)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output = try encoder.encode(report)
        guard output.count <= 33_554_432 else { throw PlacementError.invalid("output exceeds 32 MiB") }
        return output
    }
}

struct PlacementEnvelope: Codable, Sendable {
    let schema: String
    let request: PlacementRequest
    let measurements: PlacementMeasurements
    let objective: PlacementObjective
}
