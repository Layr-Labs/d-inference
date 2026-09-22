import Foundation

/// Local lifecycle telemetry only. Client telemetry upload remains disabled.
/// No command IDs, inference IDs, models, prompts or response data enter it.
enum ProviderDrainTelemetry {
    struct Event: Codable, Equatable {
        let operation: String
        let reason: String
        let inFlight: Int
        let coordinatorAcknowledged: Bool

        enum CodingKeys: String, CodingKey {
            case operation, reason
            case inFlight = "in_flight"
            case coordinatorAcknowledged = "coordinator_acknowledged"
        }
    }

    static func data(_ status: ProviderDrainStatus) -> Data {
        let event = Event(operation: "provider_drain", reason: status.outcome.rawValue,
                          inFlight: status.remaining, coordinatorAcknowledged: status.coordinatorAcknowledged)
        return (try? JSONEncoder().encode(event)) ?? Data()
    }

    static func emit(_ status: ProviderDrainStatus) {
        var line = data(status)
        line.append(0x0A)
        try? FileHandle.standardError.write(contentsOf: line)
    }
}
