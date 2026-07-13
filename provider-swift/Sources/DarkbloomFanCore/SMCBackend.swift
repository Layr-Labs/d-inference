import Foundation

#if os(macOS)
import Darwin
import IOKit
#endif

public protocol SMCBackend: Sendable {
    func keyInfo(for key: SMCKey) throws -> SMCKeyInfo
    func read(_ key: SMCKey) throws -> SMCValue
    func write(_ key: SMCKey, bytes: [UInt8]) throws
}

#if os(macOS)
private let smcKernelSelector: UInt32 = 2
private let smcReadBytesCommand: UInt8 = 5
private let smcWriteBytesCommand: UInt8 = 6
private let smcReadKeyInfoCommand: UInt8 = 9
private let smcKeyNotFoundResult: UInt8 = 0x84

private struct SMCRawVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCRawPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCRawKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C's SMCKeyData_keyInfo_t has 4-byte alignment and therefore three
    // trailing padding bytes. Swift embeds a nested struct using its size,
    // not its stride, so the padding must be explicit to keep the following
    // result/status/data fields at the AppleSMC ABI offsets.
    var padding0: UInt8 = 0
    var padding1: UInt8 = 0
    var padding2: UInt8 = 0
}

private struct SMCRawBytes {
    var b00: UInt8 = 0
    var b01: UInt8 = 0
    var b02: UInt8 = 0
    var b03: UInt8 = 0
    var b04: UInt8 = 0
    var b05: UInt8 = 0
    var b06: UInt8 = 0
    var b07: UInt8 = 0
    var b08: UInt8 = 0
    var b09: UInt8 = 0
    var b10: UInt8 = 0
    var b11: UInt8 = 0
    var b12: UInt8 = 0
    var b13: UInt8 = 0
    var b14: UInt8 = 0
    var b15: UInt8 = 0
    var b16: UInt8 = 0
    var b17: UInt8 = 0
    var b18: UInt8 = 0
    var b19: UInt8 = 0
    var b20: UInt8 = 0
    var b21: UInt8 = 0
    var b22: UInt8 = 0
    var b23: UInt8 = 0
    var b24: UInt8 = 0
    var b25: UInt8 = 0
    var b26: UInt8 = 0
    var b27: UInt8 = 0
    var b28: UInt8 = 0
    var b29: UInt8 = 0
    var b30: UInt8 = 0
    var b31: UInt8 = 0

    mutating func store(_ source: [UInt8]) {
        withUnsafeMutableBytes(of: &self) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: source)
        }
    }

    func load(count: Int) -> [UInt8] {
        withUnsafeBytes(of: self) { Array($0.prefix(count)) }
    }
}

private struct SMCRawKeyData {
    var key: UInt32 = 0
    var version = SMCRawVersion()
    var pLimitData = SMCRawPLimitData()
    var keyInfo = SMCRawKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCRawBytes()
}

public final class AppleSMCBackend: SMCBackend, @unchecked Sendable {
    public static let expectedABISize = 80
    public static var abiStride: Int { MemoryLayout<SMCRawKeyData>.stride }
    public static var abiOffsets: [String: Int] {
        [
            "key": MemoryLayout<SMCRawKeyData>.offset(of: \.key) ?? -1,
            "version": MemoryLayout<SMCRawKeyData>.offset(of: \.version) ?? -1,
            "pLimitData": MemoryLayout<SMCRawKeyData>.offset(of: \.pLimitData) ?? -1,
            "keyInfo": MemoryLayout<SMCRawKeyData>.offset(of: \.keyInfo) ?? -1,
            "result": MemoryLayout<SMCRawKeyData>.offset(of: \.result) ?? -1,
            "status": MemoryLayout<SMCRawKeyData>.offset(of: \.status) ?? -1,
            "data8": MemoryLayout<SMCRawKeyData>.offset(of: \.data8) ?? -1,
            "data32": MemoryLayout<SMCRawKeyData>.offset(of: \.data32) ?? -1,
            "bytes": MemoryLayout<SMCRawKeyData>.offset(of: \.bytes) ?? -1,
        ]
    }

    private let lock = NSLock()
    private var connection: io_connect_t

    public init() throws {
        let actualSize = MemoryLayout<SMCRawKeyData>.stride
        guard actualSize == Self.expectedABISize else {
            throw SMCError.invalidStructLayout(
                expected: Self.expectedABISize,
                actual: actualSize
            )
        }

        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCError.serviceNotFound
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == kIOReturnSuccess else {
            throw Self.mapIOError(result, operation: .open, key: nil)
        }
        connection = opened
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    public func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        try lock.withLock {
            try readKeyInfoLocked(key)
        }
    }

    public func read(_ key: SMCKey) throws -> SMCValue {
        try lock.withLock {
            let info = try readKeyInfoLocked(key)
            var input = SMCRawKeyData()
            input.key = key.code
            input.keyInfo.dataSize = UInt32(info.dataSize)
            input.data8 = smcReadBytesCommand
            let output = try callLocked(input, operation: .readBytes, key: key)
            return try SMCValue(
                key: key,
                info: info,
                bytes: output.bytes.load(count: info.dataSize)
            )
        }
    }

    public func write(_ key: SMCKey, bytes: [UInt8]) throws {
        try lock.withLock {
            let info = try readKeyInfoLocked(key)
            guard info.dataSize <= 32 else {
                throw SMCError.invalidDataSize(key: key, size: info.dataSize)
            }
            guard bytes.count == info.dataSize else {
                throw SMCError.dataLengthMismatch(
                    key: key,
                    expected: info.dataSize,
                    actual: bytes.count
                )
            }

            var input = SMCRawKeyData()
            input.key = key.code
            input.keyInfo.dataSize = UInt32(info.dataSize)
            input.keyInfo.dataType = info.dataType.code
            input.data8 = smcWriteBytesCommand
            input.bytes.store(bytes)
            _ = try callLocked(input, operation: .writeBytes, key: key)
        }
    }

    private func readKeyInfoLocked(_ key: SMCKey) throws -> SMCKeyInfo {
        var input = SMCRawKeyData()
        input.key = key.code
        input.data8 = smcReadKeyInfoCommand
        let output = try callLocked(input, operation: .readKeyInfo, key: key)
        let size = Int(output.keyInfo.dataSize)
        guard (0...32).contains(size) else {
            throw SMCError.invalidDataSize(key: key, size: size)
        }
        return SMCKeyInfo(
            dataSize: size,
            dataType: SMCDataType(code: output.keyInfo.dataType),
            attributes: output.keyInfo.dataAttributes
        )
    }

    private func callLocked(
        _ input: SMCRawKeyData,
        operation: SMCOperation,
        key: SMCKey?
    ) throws -> SMCRawKeyData {
        var input = input
        var output = SMCRawKeyData()
        var outputSize = MemoryLayout<SMCRawKeyData>.stride
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    smcKernelSelector,
                    inputPointer,
                    MemoryLayout<SMCRawKeyData>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == kIOReturnSuccess else {
            throw Self.mapIOError(result, operation: operation, key: key)
        }
        guard outputSize == MemoryLayout<SMCRawKeyData>.stride else {
            throw SMCError.invalidStructLayout(
                expected: MemoryLayout<SMCRawKeyData>.stride,
                actual: outputSize
            )
        }
        guard output.result == 0 else {
            if output.result == smcKeyNotFoundResult, let key {
                throw SMCError.keyNotFound(key)
            }
            throw SMCError.firmwareRejected(
                operation: operation,
                key: key ?? "????",
                result: output.result
            )
        }
        return output
    }

    private static func mapIOError(
        _ result: kern_return_t,
        operation: SMCOperation,
        key: SMCKey?
    ) -> SMCError {
        if result == kIOReturnNotPrivileged {
            return .notPrivileged(operation: operation, key: key)
        }
        if operation == .open {
            return .openFailed(code: Int32(result))
        }
        return .callFailed(operation: operation, key: key, code: Int32(result))
    }
}

#else

public final class AppleSMCBackend: SMCBackend, @unchecked Sendable {
    public static let expectedABISize = 80
    public static var abiStride: Int { expectedABISize }
    public static var abiOffsets: [String: Int] {
        [
            "key": 0, "version": 4, "pLimitData": 12, "keyInfo": 28,
            "result": 40, "status": 41, "data8": 42, "data32": 44, "bytes": 48,
        ]
    }

    public init() throws {
        throw SMCError.unsupportedPlatform
    }

    public func keyInfo(for _: SMCKey) throws -> SMCKeyInfo {
        throw SMCError.unsupportedPlatform
    }

    public func read(_: SMCKey) throws -> SMCValue {
        throw SMCError.unsupportedPlatform
    }

    public func write(_: SMCKey, bytes _: [UInt8]) throws {
        throw SMCError.unsupportedPlatform
    }
}

#endif
