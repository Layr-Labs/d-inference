import Foundation
import IOKit

struct SMCKey: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(_ name: String) {
        let bytes = Array(name.utf8)
        precondition(bytes.count == 4 && bytes.allSatisfy { $0 < 0x80 })
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var name: String {
        String(bytes: [
            UInt8((rawValue >> 24) & 0xff),
            UInt8((rawValue >> 16) & 0xff),
            UInt8((rawValue >> 8) & 0xff),
            UInt8(rawValue & 0xff),
        ], encoding: .ascii) ?? "????"
    }

    var description: String { name }
}

struct SMCValue: Sendable, Equatable {
    let key: SMCKey
    let dataType: UInt32
    let bytes: [UInt8]

    var dataTypeName: String {
        SMCKey(rawValue: dataType).name
    }

    var uint8: UInt8? {
        bytes.count == 1 ? bytes[0] : nil
    }

    var uint16: UInt16? {
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    var uint32: UInt32? {
        guard bytes.count == 4 else { return nil }
        return (UInt32(bytes[0]) << 24) |
            (UInt32(bytes[1]) << 16) |
            (UInt32(bytes[2]) << 8) |
            UInt32(bytes[3])
    }

    var numeric: Double? {
        switch dataTypeName {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) |
                (UInt32(bytes[1]) << 8) |
                (UInt32(bytes[2]) << 16) |
                (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "fpe2":
            return uint16.map { Double($0) / 4 }
        case "sp78":
            guard bytes.count == 2 else { return nil }
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: bits)) / 256
        case "ui8 ":
            return uint8.map(Double.init)
        case "ui16":
            return uint16.map(Double.init)
        case "ui32":
            return uint32.map(Double.init)
        default:
            return nil
        }
    }

    func encodeRPM(_ rpm: Double) throws -> [UInt8] {
        switch dataTypeName {
        case "flt ":
            let bits = Float(rpm).bitPattern
            return [
                UInt8(bits & 0xff),
                UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff),
                UInt8((bits >> 24) & 0xff),
            ]
        case "fpe2":
            let scaled = UInt16(clamping: Int((rpm * 4).rounded()))
            return [UInt8(scaled >> 8), UInt8(scaled & 0xff)]
        default:
            throw FanControlError.unsupportedSMCType(
                key: key.name,
                type: dataTypeName
            )
        }
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpu: UInt32 = 0
    var gpu: UInt32 = 0
    var memory: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCParameter {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

final class AppleSMC {
    static let parameterSize = MemoryLayout<SMCParameter>.stride

    private enum Command: UInt8 {
        case read = 5
        case write = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private static let callSelector: UInt32 = 2
    private static let keyNotFoundResult: UInt8 = 0x84
    private static let notPrivilegedCodes: Set<UInt32> = [
        0xe000_02c1,
        0xe000_02e2,
    ]

    private var connection: io_connect_t = 0
    private var infoCache: [SMCKey: SMCKeyInfo] = [:]

    init() throws {
        guard Self.parameterSize == 80 else {
            throw FanControlError.smcABIMismatch(Self.parameterSize)
        }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else {
            throw FanControlError.appleSMCUnavailable
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw FanControlError.smcOpenFailed(UInt32(bitPattern: result))
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        let info = try keyInfo(for: key)
        guard info.dataSize <= 32 else {
            throw FanControlError.invalidSMCData(
                "\(key.name) has \(info.dataSize) bytes"
            )
        }

        var input = SMCParameter()
        input.key = key.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.read.rawValue
        let output = try call(input, key: key)
        var outputCopy = output
        let bytes = withUnsafeBytes(of: &outputCopy.bytes) {
            Array($0.prefix(Int(info.dataSize)))
        }
        return SMCValue(key: key, dataType: info.dataType, bytes: bytes)
    }

    func readIfPresent(_ key: SMCKey) throws -> SMCValue? {
        do {
            return try read(key)
        } catch FanControlError.smcKeyNotFound(_) {
            return nil
        }
    }

    func write(_ key: SMCKey, bytes: [UInt8]) throws {
        let info = try keyInfo(for: key)
        guard bytes.count == Int(info.dataSize), bytes.count <= 32 else {
            throw FanControlError.invalidSMCData(
                "\(key.name) requires \(info.dataSize) bytes, got \(bytes.count)"
            )
        }

        var input = SMCParameter()
        input.key = key.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.write.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { destination in
            destination.copyBytes(from: bytes)
        }
        _ = try call(input, key: key)
    }

    func keyCount() throws -> UInt32 {
        let value = try read(SMCKey("#KEY"))
        guard value.bytes.count == 4 else {
            throw FanControlError.invalidSMCData("#KEY is not four bytes")
        }

        let bigEndian = value.uint32 ?? 0
        let littleEndian = UInt32(value.bytes[0]) |
            (UInt32(value.bytes[1]) << 8) |
            (UInt32(value.bytes[2]) << 16) |
            (UInt32(value.bytes[3]) << 24)
        if (1...10_000).contains(bigEndian) {
            return bigEndian
        }
        if (1...10_000).contains(littleEndian) {
            return littleEndian
        }
        throw FanControlError.invalidSMCData(
            "#KEY reported an implausible key count"
        )
    }

    func key(at index: UInt32) throws -> SMCKey {
        var input = SMCParameter()
        input.command = Command.keyAtIndex.rawValue
        input.data32 = index
        return SMCKey(rawValue: try call(input, key: nil).key)
    }

    private func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        if let cached = infoCache[key] {
            return cached
        }

        var input = SMCParameter()
        input.key = key.rawValue
        input.command = Command.keyInfo.rawValue
        let info = try call(input, key: key).keyInfo
        guard info.dataSize > 0, info.dataSize <= 32 else {
            throw FanControlError.invalidSMCData(
                "\(key.name) has invalid size \(info.dataSize)"
            )
        }
        infoCache[key] = info
        return info
    }

    private func call(_ input: SMCParameter, key: SMCKey?) throws -> SMCParameter {
        var inputCopy = input
        var output = SMCParameter()
        var outputSize = Self.parameterSize
        let result = withUnsafePointer(to: &inputCopy) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.callSelector,
                    inputPointer,
                    Self.parameterSize,
                    outputPointer,
                    &outputSize
                )
            }
        }

        let rawResult = UInt32(bitPattern: result)
        if Self.notPrivilegedCodes.contains(rawResult) {
            throw FanControlError.smcPermissionDenied
        }
        guard result == kIOReturnSuccess else {
            throw FanControlError.smcCallFailed(rawResult)
        }
        guard outputSize == Self.parameterSize else {
            throw FanControlError.invalidSMCData(
                "AppleSMC returned \(outputSize) bytes"
            )
        }
        if output.result == Self.keyNotFoundResult {
            throw FanControlError.smcKeyNotFound(key?.name ?? "index")
        }
        guard output.result == 0 else {
            throw FanControlError.smcRejected(
                key: key?.name ?? "index",
                result: output.result
            )
        }
        return output
    }
}
