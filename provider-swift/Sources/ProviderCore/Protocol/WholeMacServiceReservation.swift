import Foundation

/// Opaque coordinator attempt identity and its actual held service charge.
/// Local leases contribute to the total without publishing an identity.
public struct WholeMacServiceReservation: Codable, Sendable, Equatable {
    public var id: String
    public var usedFraction: Double

    public init(id: String, usedFraction: Double) {
        self.id = id
        self.usedFraction = usedFraction
    }

    enum CodingKeys: String, CodingKey {
        case id
        case usedFraction = "used_fraction"
    }
}
