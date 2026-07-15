import DarkbloomFanCore
import Foundation

struct FanHardwareRecovery {
    static let retryIntervalSeconds: TimeInterval = 5

    private(set) var inventory: FanInventory
    private(set) var discoveryRequired: Bool
    private(set) var discoveryError: String?
    private(set) var quarantinedSensorKeys: Set<SMCKey> = []
    private var minimumSensorCount: Int
    private var lastDiscoveryAt = -Double.infinity

    init(inventory: FanInventory, initialError: String?) {
        self.inventory = inventory
        self.discoveryError = initialError
        self.discoveryRequired = initialError != nil
            || inventory.fans.isEmpty
            || inventory.gpuTemperatureKeys.isEmpty
        self.minimumSensorCount = inventory.gpuTemperatureKeys.isEmpty
            ? 1
            : max(1, (inventory.gpuTemperatureKeys.count + 1) / 2)
    }

    var hardwareReady: Bool {
        !discoveryRequired
            && !inventory.fans.isEmpty
            && inventory.gpuTemperatureKeys.count >= minimumSensorCount
    }

    var recoveryPending: Bool {
        !hardwareReady
            && !inventory.fans.isEmpty
            && !GPUTemperatureCatalog.keys(for: inventory.chipFamily).isEmpty
    }

    var readinessMessage: String {
        if inventory.fans.isEmpty {
            return "fan control unsupported: this Mac reports no controllable fans"
        }
        let catalog = GPUTemperatureCatalog.keys(for: inventory.chipFamily)
        if catalog.isEmpty {
            return "fan control unsupported: no GPU sensor catalog exists for \(inventory.chipFamily.rawValue)"
        }
        if let discoveryError {
            return discoveryError
        }
        return "GPU sensors are not ready (\(inventory.gpuTemperatureKeys.count)/\(minimumSensorCount) required); discovery will retry"
    }

    mutating func markInvalidSensor(_ key: SMCKey) {
        quarantinedSensorKeys.insert(key)
        discoveryRequired = true
        lastDiscoveryAt = -Double.infinity
        discoveryError = "GPU sensor \(key) became invalid; restoring Auto before rediscovery"
    }

    mutating func markWake() {
        discoveryRequired = true
        lastDiscoveryAt = -Double.infinity
        discoveryError = "GPU sensor discovery is refreshing after system wake"
    }

    mutating func beginDiscoveryIfDue(now: TimeInterval) -> Bool {
        guard discoveryRequired,
              now - lastDiscoveryAt >= Self.retryIntervalSeconds
        else {
            return false
        }
        lastDiscoveryAt = now
        return true
    }

    @discardableResult
    mutating func apply(_ refreshed: FanInventory) -> Bool {
        let required = max(
            minimumSensorCount,
            refreshed.gpuTemperatureKeys.isEmpty
                ? 1
                : max(1, (refreshed.gpuTemperatureKeys.count + 1) / 2)
        )
        inventory = refreshed
        minimumSensorCount = required

        guard !refreshed.fans.isEmpty,
              refreshed.gpuTemperatureKeys.count >= required
        else {
            discoveryRequired = true
            discoveryError = "GPU sensor discovery found \(refreshed.gpuTemperatureKeys.count)/\(required) required sensors for \(refreshed.chipFamily.rawValue); retrying"
            return false
        }

        let discoveredKeys = Set(refreshed.gpuTemperatureKeys)
        quarantinedSensorKeys = Set(quarantinedSensorKeys.filter {
            !discoveredKeys.contains($0)
        })
        discoveryRequired = false
        discoveryError = nil
        return true
    }

    mutating func recordDiscoveryFailure(_ error: Error) {
        discoveryRequired = true
        discoveryError = "fan hardware discovery failed: \(error); retrying"
    }
}
