import Darwin
import Foundation
import MLX

enum QwenProtectedResources {
    static func requireLive(additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0) throws {
        try requireMachine()
        try QwenResidentResourceEnvironment.require()
        let os = try QwenDenseStageLoadResources.requireInitial()
        guard os.pressureLevel == 1, [24, 48].contains(os.physicalMemoryBytes / 1_073_741_824),
              os.physicalMemoryBytes % 1_073_741_824 == 0,
              additionalNativeBytes >= 0, additionalHostBytes >= 0 else {
            throw ProbeError("Protected experiment requires its measured machine and normal pressure")
        }
        let sum = QwenLongPrefillCheckedBytes.sum
        let requiredFree = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try sum([QwenResidentProtectedExperiment.reservedBytes, additionalNativeBytes,
                additionalHostBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let requiredNative = try sum([Memory.activeMemory, Memory.cacheMemory,
            QwenResidentProtectedExperiment.nativeAllowanceBytes, additionalNativeBytes,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard os.actualFreeBytes >= requiredFree, Memory.memoryLimit >= requiredNative,
              Memory.cacheLimit == 0 else { throw ProbeError("Protected experiment exceeds live resource policy") }
        // Two maximum native copy allocations plus the complete observed native
        // peak fit the separate allocator charge; it is NOT subtracted from OS.
        let frame = try QwenResidentResourceEnvironment.allocationBound(QwenResidentProtectedExperiment.maximumFrameBytes)
        let plain = try QwenResidentResourceEnvironment.allocationBound(QwenResidentProtectedExperiment.maximumPlaintextBytes)
        guard try sum([frame, plain, QwenResidentProtectedExperiment.observedNativeIncrement,
                       QwenResidentProtectedExperiment.keyAndMetadataAllowance])
                <= QwenResidentProtectedExperiment.nativeAllowanceBytes else {
            throw ProbeError("Protected native staging allocation bound changed")
        }
    }

    static func requireMachine() throws {
        guard try systemString("hw.model") == "Mac16,7", try systemString("kern.osversion") == "26A428" else {
            throw ProbeError("Protected experiment machine/OS differs from retained allocation evidence")
        }
    }

    private static func systemString(_ name: String) throws -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, (1...256).contains(count) else {
            throw ProbeError("Protected system identity unavailable")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &count, nil, 0) }
        guard status == 0, count == bytes.count, bytes.last == 0,
              let value = String(bytes: bytes.dropLast(), encoding: .utf8), !value.isEmpty else {
            throw ProbeError("Protected system identity malformed")
        }
        return value
    }
}

/// Pure geometry check, before any resource/native allocation query.
enum QwenProtectedArrayGeometry {
    static func require(shape: [Int], dtype: DType) throws {
        let allowed = (dtype == .uint32 && shape == [1])
            || (dtype == .int32 && shape == [64])
            || (dtype == .uint8 && shape.count == 1 && (1...16_384).contains(shape[0]))
            || (dtype == .bfloat16 && (shape == [1, 16, 4096] || shape == [1, 1, 4096]))
        guard allowed else { throw ProbeError("Protected experiment operation geometry differs") }
    }
}
