import DarkbloomFanCore
import DarkbloomFanService
import Foundation

struct FanHardwareRecovery {
    static let retryIntervalSeconds: TimeInterval = 5

    private(set) var inventory: FanInventory
    private(set) var discoveryRequired: Bool
    private(set) var discoveryError: String?
    private(set) var quarantinedSensorKeys: Set<SMCKey> = []
    private(set) var baselineNeedsPersistence: Bool
    private var baselineSensorKeys: Set<SMCKey>
    private var minimumSensorCount: Int
    private var lastDiscoveryAt = -Double.infinity

    init(
        inventory: FanInventory,
        initialError: String?,
        baselineSensorKeys: [SMCKey] = []
    ) {
        let persistedBaseline = Set(baselineSensorKeys)
        let catalogMinimum = GPUTemperatureCatalog.minimumReadyCount(
            for: inventory.chipFamily
        )
        let baselineMinimum = persistedBaseline.isEmpty
            ? 1
            : max(1, (persistedBaseline.count + 1) / 2)
        let minimumSensorCount = max(catalogMinimum, baselineMinimum)
        let discoveredKeys = Set(inventory.gpuTemperatureKeys)
        let requiredOverlap = persistedBaseline.isEmpty
            ? 0
            : baselineMinimum
        let initialQuorum = discoveredKeys.count >= minimumSensorCount
            && discoveredKeys.intersection(persistedBaseline).count
                >= requiredOverlap

        self.inventory = inventory
        self.discoveryError = initialError
        self.discoveryRequired = initialError != nil
            || inventory.fans.isEmpty
            || !initialQuorum
        self.minimumSensorCount = minimumSensorCount
        self.baselineSensorKeys = persistedBaseline
        if initialQuorum {
            self.baselineSensorKeys.formUnion(discoveredKeys)
        }
        self.baselineNeedsPersistence = initialQuorum
            && self.baselineSensorKeys != persistedBaseline
    }

    var hardwareReady: Bool {
        !discoveryRequired
            && !inventory.fans.isEmpty
            && inventory.gpuTemperatureKeys.count >= minimumSensorCount
    }

    var recoveryPending: Bool {
        discoveryRequired
            && !GPUTemperatureCatalog.keys(for: inventory.chipFamily).isEmpty
    }

    var readinessMessage: String {
        if inventory.fans.isEmpty {
            if recoveryPending {
                return "fan hardware discovery found no controllable fans; retrying"
            }
            return "fan control unsupported: this Mac reports no controllable fans"
        }
        let catalog = GPUTemperatureCatalog.keys(for: inventory.chipFamily)
        if catalog.isEmpty {
            return "fan control unsupported: no GPU sensor catalog exists for \(inventory.chipFamily.rawValue)"
        }
        if let discoveryError {
            return discoveryError
        }
        let overlap = Set(inventory.gpuTemperatureKeys)
            .intersection(baselineSensorKeys)
            .count
        let requiredOverlap = baselineSensorKeys.isEmpty
            ? 0
            : max(1, (baselineSensorKeys.count + 1) / 2)
        return "GPU sensors are not ready (count \(inventory.gpuTemperatureKeys.count)/\(minimumSensorCount), baseline overlap \(overlap)/\(requiredOverlap)); discovery will retry"
    }

    mutating func markSensorFailure(_ error: Error) {
        if let key = Self.sensorKey(from: error) {
            quarantinedSensorKeys.insert(key)
        }
        discoveryRequired = true
        lastDiscoveryAt = -Double.infinity
        discoveryError = "GPU sensor read failed: \(error); restoring Auto before rediscovery"
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
        let refreshedKeys = Set(refreshed.gpuTemperatureKeys)
        let requiredOverlap = baselineSensorKeys.isEmpty
            ? 0
            : max(1, (baselineSensorKeys.count + 1) / 2)
        inventory = refreshed

        guard !refreshed.fans.isEmpty,
              refreshedKeys.count >= minimumSensorCount,
              refreshedKeys.intersection(baselineSensorKeys).count
                >= requiredOverlap
        else {
            discoveryRequired = true
            discoveryError = readinessMessage
            return false
        }

        quarantinedSensorKeys = Set(quarantinedSensorKeys.filter {
            !refreshedKeys.contains($0)
        })
        let priorBaseline = baselineSensorKeys
        baselineSensorKeys.formUnion(refreshedKeys)
        minimumSensorCount = max(
            minimumSensorCount,
            max(1, (baselineSensorKeys.count + 1) / 2)
        )
        baselineNeedsPersistence = baselineNeedsPersistence
            || baselineSensorKeys != priorBaseline
        discoveryRequired = false
        discoveryError = nil
        return true
    }

    mutating func recordDiscoveryFailure(_ error: Error) {
        discoveryRequired = true
        discoveryError = "fan hardware discovery failed: \(error); retrying"
    }

    var sensorBaseline: FanSensorBaseline {
        FanSensorBaseline(
            chipFamily: inventory.chipFamily,
            sensorKeys: Array(baselineSensorKeys)
        )
    }

    mutating func markBaselinePersisted() {
        baselineNeedsPersistence = false
    }

    private static func sensorKey(from error: Error) -> SMCKey? {
        if let hardware = error as? FanHardwareError {
            switch hardware {
            case .invalidTemperature(let key, _):
                return key
            case .backend(let smc):
                return sensorKey(from: smc)
            default:
                return nil
            }
        }
        guard let smc = error as? SMCError else { return nil }
        switch smc {
        case .callFailed(_, let key, _), .notPrivileged(_, let key):
            return key
        case .keyNotFound(let key),
             .firmwareRejected(_, let key, _),
             .invalidDataSize(let key, _),
             .dataLengthMismatch(let key, _, _),
             .typeMismatch(let key, _, _),
             .unsupportedDataType(let key, _),
             .nonFiniteValue(let key):
            return key
        default:
            return nil
        }
    }
}
