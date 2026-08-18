import Foundation

struct SystemProfilerMachineIdentityProvider: Sendable {
    func current() async -> MachineIdentity {
        #if DEBUG
        if let previewIdentity = Self.previewIdentity {
            return previewIdentity
        }
        #endif

        return await Task.detached(priority: .userInitiated) {
            (try? Self.readMachineIdentity()) ?? .fallback
        }.value
    }

    #if DEBUG
    private static var previewIdentity: MachineIdentity? {
        previewIdentity(environment: ProcessInfo.processInfo.environment)
    }

    /// Product previews need a deterministic local identity so "This Mac"
    /// never depends on whichever developer machine renders the fixture.
    static func previewIdentity(environment: [String: String]) -> MachineIdentity? {
        let requestedMachine = environment["DARKBLOOM_PREVIEW_MACHINE"]
            ?? (environment["DARKBLOOM_PREVIEW_PRODUCT_DESTINATION"]?.lowercased() == "my-macs"
                ? "macbook-pro"
                : nil)

        switch requestedMachine {
        case "macbook-pro":
            return MachineIdentity(
                displayName: "MacBook Pro",
                modelIdentifier: "Mac16,5",
                chipName: "Apple M4 Max",
                modelNumber: "Z1FW0007BLL/A",
                serialNumber: "FVFGH0STQ6L4",
                physicalMemoryBytes: 128 * 1_024 * 1_024 * 1_024,
                storageTotalBytes: 4_000_000_000_000,
                storageAvailableBytes: 1_820_000_000_000,
                processorCoreCount: 16,
                gpuCoreCount: 40
            )
        case "mac-mini":
            return MachineIdentity(
                displayName: "Mac mini",
                modelIdentifier: "Mac16,10",
                chipName: "Apple M4 Pro",
                modelNumber: "MCX44LL/A",
                serialNumber: "C07QMINI2025",
                physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
                storageTotalBytes: 2_000_000_000_000,
                storageAvailableBytes: 1_240_000_000_000,
                processorCoreCount: 14,
                gpuCoreCount: 20
            )
        case "mac-studio":
            return MachineIdentity(
                displayName: "Mac Studio",
                modelIdentifier: "Mac15,14",
                chipName: "Apple M3 Ultra",
                modelNumber: "MU963LL/A",
                serialNumber: "H2YVQ0STUDIO",
                physicalMemoryBytes: 192 * 1_024 * 1_024 * 1_024,
                storageTotalBytes: 8_000_000_000_000,
                storageAvailableBytes: 6_100_000_000_000,
                processorCoreCount: 32,
                gpuCoreCount: 80
            )
        default:
            return nil
        }
    }
    #endif

    private static func readMachineIdentity() throws -> MachineIdentity {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "SPDisplaysDataType", "-json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MachineIdentityError.profilerFailed(process.terminationStatus)
        }

        let payload = try JSONDecoder().decode(HardwareProfilePayload.self, from: data)
        guard let hardware = payload.hardware.first else {
            throw MachineIdentityError.missingHardwareProfile
        }

        return MachineIdentity(
            displayName: hardware.machineName ?? "Mac",
            modelIdentifier: hardware.machineModel ?? "",
            chipName: hardware.chipType ?? "Apple silicon",
            modelNumber: hardware.modelNumber,
            serialNumber: hardware.serialNumber,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            storageTotalBytes: storage.total,
            storageAvailableBytes: storage.available,
            processorCoreCount: hardware.processorCoreCount,
            gpuCoreCount: payload.displays?.compactMap(\.coreCount).first
        )
    }

    private static var storage: (total: UInt64?, available: UInt64?) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return (nil, nil)
        }

        let total = (attributes[.systemSize] as? NSNumber)?.uint64Value
        let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
        return (total, available)
    }
}

private struct HardwareProfilePayload: Decodable {
    let hardware: [HardwareProfile]
    let displays: [DisplayProfile]?

    enum CodingKeys: String, CodingKey {
        case hardware = "SPHardwareDataType"
        case displays = "SPDisplaysDataType"
    }
}

private struct DisplayProfile: Decodable {
    let gpuCores: String?

    var coreCount: Int? {
        gpuCores.flatMap(Int.init)
    }

    enum CodingKeys: String, CodingKey {
        case gpuCores = "sppci_cores"
    }
}

private struct HardwareProfile: Decodable {
    let machineName: String?
    let machineModel: String?
    let modelNumber: String?
    let chipType: String?
    let serialNumber: String?
    let numberProcessors: String?

    var processorCoreCount: Int? {
        guard let numberProcessors else { return nil }
        let firstNumber = numberProcessors
            .split(whereSeparator: { !$0.isNumber })
            .first
        return firstNumber.flatMap { Int($0) }
    }

    enum CodingKeys: String, CodingKey {
        case machineName = "machine_name"
        case machineModel = "machine_model"
        case modelNumber = "model_number"
        case chipType = "chip_type"
        case serialNumber = "serial_number"
        case numberProcessors = "number_processors"
    }
}

private enum MachineIdentityError: Error {
    case profilerFailed(Int32)
    case missingHardwareProfile
}
