import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum FanChipFamily: String, Codable, CaseIterable, Sendable {
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"
    case unknown = "Unknown"

    public init(brandString: String) {
        let tokens = brandString.uppercased().split {
            !$0.isLetter && !$0.isNumber
        }
        if tokens.contains("M5") {
            self = .m5
        } else if tokens.contains("M4") {
            self = .m4
        } else if tokens.contains("M3") {
            self = .m3
        } else if tokens.contains("M2") {
            self = .m2
        } else if tokens.contains("M1") {
            self = .m1
        } else {
            self = .unknown
        }
    }
}

public enum FanMode: Equatable, Codable, Sendable {
    case automatic
    case manual
    case system
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .automatic
        case 1: self = .manual
        case 3: self = .system
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .automatic: return 0
        case .manual: return 1
        case .system: return 3
        case .unknown(let value): return value
        }
    }

    public var isAutomatic: Bool {
        self == .automatic || self == .system
    }
}

public struct FanCapability: Equatable, Codable, Sendable {
    public let index: Int
    public let actualKey: SMCKey
    public let minimumKey: SMCKey
    public let maximumKey: SMCKey
    public let targetKey: SMCKey
    public let modeKey: SMCKey

    public init(
        index: Int,
        actualKey: SMCKey,
        minimumKey: SMCKey,
        maximumKey: SMCKey,
        targetKey: SMCKey,
        modeKey: SMCKey
    ) {
        self.index = index
        self.actualKey = actualKey
        self.minimumKey = minimumKey
        self.maximumKey = maximumKey
        self.targetKey = targetKey
        self.modeKey = modeKey
    }
}

public struct FanInventory: Equatable, Codable, Sendable {
    public let chipFamily: FanChipFamily
    public let fans: [FanCapability]
    public let gpuTemperatureKeys: [SMCKey]
    public let ftstKey: SMCKey?
    public let fanLimits: [Int: FanLimits]

    public init(
        chipFamily: FanChipFamily,
        fans: [FanCapability],
        gpuTemperatureKeys: [SMCKey],
        ftstKey: SMCKey?,
        fanLimits: [Int: FanLimits] = [:]
    ) {
        self.chipFamily = chipFamily
        self.fans = fans
        self.gpuTemperatureKeys = gpuTemperatureKeys
        self.ftstKey = ftstKey
        self.fanLimits = fanLimits
    }
}

public struct FanLimits: Equatable, Codable, Sendable {
    public let minimumRPM: Double
    public let maximumRPM: Double

    public init(minimumRPM: Double, maximumRPM: Double) {
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }
}

public struct FanReading: Equatable, Codable, Sendable {
    public let capability: FanCapability
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    public let mode: FanMode

    public init(
        capability: FanCapability,
        actualRPM: Double,
        minimumRPM: Double,
        maximumRPM: Double,
        targetRPM: Double,
        mode: FanMode
    ) {
        self.capability = capability
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }
}

public struct GPUTemperatureReading: Equatable, Codable, Sendable {
    public let key: SMCKey
    public let celsius: Double

    public init(key: SMCKey, celsius: Double) {
        self.key = key
        self.celsius = celsius
    }
}

public enum FanHardwareError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidFanCount(Int)
    case missingFanKey(index: Int, key: SMCKey)
    case missingModeKey(index: Int)
    case unsupportedRPMKey(key: SMCKey, info: SMCKeyInfo)
    case unsupportedModeKey(key: SMCKey, info: SMCKeyInfo)
    case invalidFanLimits(index: Int, minimum: Double, maximum: Double)
    case invalidFanRPM(index: Int, field: String, value: Double)
    case invalidTemperature(key: SMCKey, value: Double)
    case backend(SMCError)

    public var description: String {
        switch self {
        case .invalidFanCount(let count):
            return "invalid fan count \(count)"
        case .missingFanKey(let index, let key):
            return "fan \(index) is missing required key \(key)"
        case .missingModeKey(let index):
            return "fan \(index) exposes neither F\(index)Md nor F\(index)md"
        case .unsupportedRPMKey(let key, let info):
            return "fan RPM key \(key) must be flt/4, got \(info.dataType)/\(info.dataSize)"
        case .unsupportedModeKey(let key, let info):
            return "fan mode key \(key) must be ui8/1, got \(info.dataType)/\(info.dataSize)"
        case .invalidFanLimits(let index, let minimum, let maximum):
            return "fan \(index) reported invalid limits \(minimum)...\(maximum) RPM"
        case .invalidFanRPM(let index, let field, let value):
            return "fan \(index) reported invalid \(field) RPM \(value)"
        case .invalidTemperature(let key, let value):
            return "GPU sensor \(key) reported implausible temperature \(value) C"
        case .backend(let error):
            return error.description
        }
    }
}

public enum GPUTemperatureCatalog {
    public static func keys(for family: FanChipFamily) -> [SMCKey] {
        switch family {
        case .m1:
            return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case .m2:
            return ["Tg0f", "Tg0j"]
        case .m3:
            return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case .m4:
            return [
                "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K",
                "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k",
            ]
        case .m5:
            return ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        case .unknown:
            return []
        }
    }

    public static func minimumReadyCount(for family: FanChipFamily) -> Int {
        let count = keys(for: family).count
        return count == 0 ? 1 : max(1, (count + 1) / 2)
    }
}

public enum FanChipIdentity {
    public static func currentBrandString() throws -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1
        else {
            throw SMCError.systemQueryFailed("machdep.cpu.brand_string size")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            throw SMCError.systemQueryFailed("machdep.cpu.brand_string value")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
        #else
        throw SMCError.unsupportedPlatform
        #endif
    }
}

public struct FanHardwareReader: Sendable {
    public static let maximumSupportedFans = 8
    public static let plausibleTemperatureRange = 10.0...125.0

    private let backend: any SMCBackend

    public init(backend: any SMCBackend) {
        self.backend = backend
    }

    public func discover(brandString: String? = nil) throws -> FanInventory {
        let recoveryInventory = try discoverForRecovery(brandString: brandString)
        let family = recoveryInventory.chipFamily
        let fans = recoveryInventory.fans
        let ftstKey = recoveryInventory.ftstKey
        let limits = try Dictionary(uniqueKeysWithValues: fans.map { fan in
            let minimum = try readRPM(fan.minimumKey)
            let maximum = try readRPM(fan.maximumKey)
            guard minimum > 0, maximum >= minimum else {
                throw FanHardwareError.invalidFanLimits(
                    index: fan.index,
                    minimum: minimum,
                    maximum: maximum
                )
            }
            return (
                fan.index,
                FanLimits(minimumRPM: minimum, maximumRPM: maximum)
            )
        })
        let gpuKeys: [SMCKey] = try GPUTemperatureCatalog.keys(for: family).compactMap { key in
            guard let info = try probeKey(key) else { return nil }
            guard isTemperatureType(info) else { return nil }
            let value = try mapBackend { try backend.read(key) }
            guard let temperature = try? value.number(),
                  Self.plausibleTemperatureRange.contains(temperature)
            else {
                return nil
            }
            return key
        }

        return FanInventory(
            chipFamily: family,
            fans: fans,
            gpuTemperatureKeys: gpuKeys,
            ftstKey: ftstKey,
            fanLimits: limits
        )
    }

    /// Minimal discovery for crash repair. It intentionally reads no fan-limit
    /// values or GPU sensors because affected firmware can report F?Mx=0 while
    /// manual mode is stranded and a sensor failure must never block Auto repair.
    public func discoverForRecovery(brandString: String? = nil) throws -> FanInventory {
        let brand = try brandString ?? FanChipIdentity.currentBrandString()
        let family = FanChipFamily(brandString: brand)
        let countValue = try mapBackend { try backend.read("FNum") }
        let fanCount: Int
        do {
            fanCount = Int(try countValue.uint8())
        } catch let error as SMCError {
            throw FanHardwareError.backend(error)
        }
        guard (0...Self.maximumSupportedFans).contains(fanCount) else {
            throw FanHardwareError.invalidFanCount(fanCount)
        }

        let fans = try (0..<fanCount).map(discoverFan)
        let ftstKey = try probeUI8Key("Ftst")
        return FanInventory(
            chipFamily: family,
            fans: fans,
            gpuTemperatureKeys: [],
            ftstKey: ftstKey
        )
    }

    public func fanReadings(in inventory: FanInventory) throws -> [FanReading] {
        try inventory.fans.map { fan in
            let actual = try readRPM(fan.actualKey)
            let cachedLimits = inventory.fanLimits[fan.index]
            let minimum = try cachedLimits?.minimumRPM ?? readRPM(fan.minimumKey)
            let maximum = try cachedLimits?.maximumRPM ?? readRPM(fan.maximumKey)
            let target = try readRPM(fan.targetKey)
            let modeValue = try mapBackend { try backend.read(fan.modeKey) }
            let mode: FanMode
            do {
                mode = FanMode(rawValue: try modeValue.uint8())
            } catch let error as SMCError {
                throw FanHardwareError.backend(error)
            }

            guard minimum > 0, maximum >= minimum else {
                throw FanHardwareError.invalidFanLimits(
                    index: fan.index,
                    minimum: minimum,
                    maximum: maximum
                )
            }
            guard actual >= 0 else {
                throw FanHardwareError.invalidFanRPM(
                    index: fan.index,
                    field: "actual",
                    value: actual
                )
            }
            guard target >= 0 else {
                throw FanHardwareError.invalidFanRPM(
                    index: fan.index,
                    field: "target",
                    value: target
                )
            }
            return FanReading(
                capability: fan,
                actualRPM: actual,
                minimumRPM: minimum,
                maximumRPM: maximum,
                targetRPM: target,
                mode: mode
            )
        }
    }

    public func gpuTemperatures(in inventory: FanInventory) throws -> [GPUTemperatureReading] {
        try inventory.gpuTemperatureKeys.map { key in
            let value = try mapBackend { try backend.read(key) }
            let temperature: Double
            do {
                temperature = try value.number()
            } catch let error as SMCError {
                throw FanHardwareError.backend(error)
            }
            guard Self.plausibleTemperatureRange.contains(temperature) else {
                throw FanHardwareError.invalidTemperature(key: key, value: temperature)
            }
            return GPUTemperatureReading(key: key, celsius: temperature)
        }
    }

    private func discoverFan(index: Int) throws -> FanCapability {
        let actual = try SMCKey("F\(index)Ac")
        let minimum = try SMCKey("F\(index)Mn")
        let maximum = try SMCKey("F\(index)Mx")
        let target = try SMCKey("F\(index)Tg")
        for key in [actual, minimum, maximum, target] {
            guard let info = try probeKey(key) else {
                throw FanHardwareError.missingFanKey(index: index, key: key)
            }
            guard info.dataType.rawValue == "flt ", info.dataSize == 4 else {
                throw FanHardwareError.unsupportedRPMKey(key: key, info: info)
            }
        }

        var modeKey: SMCKey?
        for candidate in [try SMCKey("F\(index)md"), try SMCKey("F\(index)Md")] {
            guard let info = try probeKey(candidate) else { continue }
            guard info.dataType.rawValue == "ui8 ", info.dataSize == 1 else {
                throw FanHardwareError.unsupportedModeKey(key: candidate, info: info)
            }
            modeKey = candidate
            break
        }
        guard let modeKey else {
            throw FanHardwareError.missingModeKey(index: index)
        }
        return FanCapability(
            index: index,
            actualKey: actual,
            minimumKey: minimum,
            maximumKey: maximum,
            targetKey: target,
            modeKey: modeKey
        )
    }

    private func readRPM(_ key: SMCKey) throws -> Double {
        let value = try mapBackend { try backend.read(key) }
        do {
            return try value.float32()
        } catch let error as SMCError {
            throw FanHardwareError.backend(error)
        }
    }

    private func probeUI8Key(_ key: SMCKey) throws -> SMCKey? {
        guard let info = try probeKey(key) else { return nil }
        guard info.dataType.rawValue == "ui8 ", info.dataSize == 1 else {
            throw FanHardwareError.unsupportedModeKey(key: key, info: info)
        }
        return key
    }

    private func probeKey(_ key: SMCKey) throws -> SMCKeyInfo? {
        do {
            return try backend.keyInfo(for: key)
        } catch let error as SMCError where error.isKeyNotFound {
            return nil
        } catch let error as SMCError {
            throw FanHardwareError.backend(error)
        } catch {
            throw FanHardwareError.backend(.injectedFailure(String(describing: error)))
        }
    }

    private func isTemperatureType(_ info: SMCKeyInfo) -> Bool {
        switch info.dataType.rawValue {
        case "flt ": return info.dataSize == 4
        case "sp78", "sp1e": return info.dataSize == 2
        default: return false
        }
    }

    private func mapBackend<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FanHardwareError {
            throw error
        } catch let error as SMCError {
            throw FanHardwareError.backend(error)
        } catch {
            throw FanHardwareError.backend(.injectedFailure(String(describing: error)))
        }
    }
}
