import Foundation

/// Local structured hold transitions, one JSON line on standard error (the
/// provider log). Like `ProviderDrainTelemetry` nothing is uploaded; lines
/// carry no hold IDs, request IDs, models, prompts or response data. The
/// coordinator learns of a hold only from heartbeat and register fields.
enum AddonHoldTelemetry {
    enum Transition: String, Sendable {
        case begin, renewed, held, released, expired, restored, reasserted
        /// A lease expired while the machine lock is held, so the hold stays.
        case keptByMachineLock = "kept_by_machine_lock"
        /// The drain bound passed; remaining accepted work was cancelled.
        case drainTimedOut = "drain_timed_out"
    }

    struct Event: Codable, Equatable {
        let operation: String
        let transition: String
        let addon: String?
        let state: String?
        let leaseSeconds: Int?
        let inFlight: Int?

        enum CodingKeys: String, CodingKey {
            case operation, transition, addon, state
            case leaseSeconds = "lease_seconds"
            case inFlight = "in_flight"
        }
    }

    static func data(_ transition: Transition, hold: AddonHold? = nil, inFlight: Int? = nil) -> Data {
        let event = Event(operation: "addon_hold", transition: transition.rawValue, addon: hold?.addon,
                          state: hold?.state.rawValue, leaseSeconds: hold?.leaseSeconds, inFlight: inFlight)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(event)) ?? Data()
    }

    static func emit(_ transition: Transition, hold: AddonHold? = nil, inFlight: Int? = nil) {
        var line = data(transition, hold: hold, inFlight: inFlight)
        line.append(0x0A)
        try? FileHandle.standardError.write(contentsOf: line)
    }
}
