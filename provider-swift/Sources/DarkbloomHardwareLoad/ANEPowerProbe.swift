import Foundation
import IOKit

/// Whether the Neural Engine is powered, from its driver's power state.
///
/// The driver keeps the ANE powered for a few seconds after work stops, so the
/// duty cycle is an upper bound on actual ANE compute.
final class ANEPowerProbe {
    static let serviceClass = "H11ANEIn"
    private let service: io_service_t

    init?() {
        guard let service = RegistryProperty.matchingService(Self.serviceClass) else { return nil }
        self.service = service
    }

    deinit { IOObjectRelease(service) }

    func isPowered() -> Bool? {
        (RegistryProperty.value(service, "IOPowerManagement") as? [String: Any])
            .flatMap(Self.powered)
    }

    static func powered(_ powerManagement: [String: Any]) -> Bool? {
        (powerManagement["CurrentPowerState"] as? NSNumber).map { $0.intValue > 0 }
    }
}

/// Fraction of polls that observed a powered state since the last drain.
struct DutyCycle {
    private var polls = 0
    private var powered = 0

    mutating func record(_ isPowered: Bool?) {
        guard let isPowered else { return }
        polls += 1
        if isPowered { powered += 1 }
    }

    mutating func drain() -> Double? {
        defer { self = DutyCycle() }
        return polls > 0 ? Double(powered) / Double(polls) : nil
    }
}
