import Foundation

struct MachineIdentity: Equatable, Sendable {
    let displayName: String
    let modelIdentifier: String
    let modelNumber: String?
    let chipName: String
    let serialNumber: String?
    let physicalMemoryBytes: UInt64?
    let storageTotalBytes: UInt64?
    let storageAvailableBytes: UInt64?
    let processorCoreCount: Int?
    let gpuCoreCount: Int?
    let formFactor: MacFormFactor
    let isDetected: Bool

    static let loading = MachineIdentity(
        displayName: "This Mac",
        modelIdentifier: "",
        modelNumber: nil,
        chipName: "Detecting Apple silicon…",
        serialNumber: nil,
        physicalMemoryBytes: nil,
        storageTotalBytes: nil,
        storageAvailableBytes: nil,
        processorCoreCount: nil,
        gpuCoreCount: nil,
        formFactor: .mac,
        isDetected: false
    )

    static let fallback = MachineIdentity(
        displayName: "Mac",
        modelIdentifier: "",
        modelNumber: nil,
        chipName: "Apple silicon",
        serialNumber: nil,
        physicalMemoryBytes: nil,
        storageTotalBytes: nil,
        storageAvailableBytes: nil,
        processorCoreCount: nil,
        gpuCoreCount: nil,
        formFactor: .mac,
        isDetected: false
    )

    init(
        displayName: String,
        modelIdentifier: String,
        chipName: String,
        modelNumber: String? = nil,
        serialNumber: String? = nil,
        physicalMemoryBytes: UInt64? = nil,
        storageTotalBytes: UInt64? = nil,
        storageAvailableBytes: UInt64? = nil,
        processorCoreCount: Int? = nil,
        gpuCoreCount: Int? = nil,
        isDetected: Bool = true
    ) {
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.modelNumber = modelNumber
        self.chipName = chipName
        self.serialNumber = serialNumber
        self.physicalMemoryBytes = physicalMemoryBytes
        self.storageTotalBytes = storageTotalBytes
        self.storageAvailableBytes = storageAvailableBytes
        self.processorCoreCount = processorCoreCount
        self.gpuCoreCount = gpuCoreCount
        formFactor = MacFormFactor.classify(
            displayName: displayName,
            modelIdentifier: modelIdentifier
        )
        self.isDetected = isDetected
    }

    private init(
        displayName: String,
        modelIdentifier: String,
        modelNumber: String?,
        chipName: String,
        serialNumber: String?,
        physicalMemoryBytes: UInt64?,
        storageTotalBytes: UInt64?,
        storageAvailableBytes: UInt64?,
        processorCoreCount: Int?,
        gpuCoreCount: Int?,
        formFactor: MacFormFactor,
        isDetected: Bool
    ) {
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.modelNumber = modelNumber
        self.chipName = chipName
        self.serialNumber = serialNumber
        self.physicalMemoryBytes = physicalMemoryBytes
        self.storageTotalBytes = storageTotalBytes
        self.storageAvailableBytes = storageAvailableBytes
        self.processorCoreCount = processorCoreCount
        self.gpuCoreCount = gpuCoreCount
        self.formFactor = formFactor
        self.isDetected = isDetected
    }
}

enum MacFormFactor: String, Equatable, Sendable {
    case macBook
    case macMini
    case macStudio
    case iMac
    case macPro
    case mac

    static func classify(displayName: String, modelIdentifier: String) -> Self {
        let name = displayName.lowercased()
        let identifier = modelIdentifier.lowercased()

        if name.contains("macbook") || identifier.contains("macbook") {
            return .macBook
        }
        if name.contains("mac mini") || identifier.contains("macmini") {
            return .macMini
        }
        if name.contains("mac studio") {
            return .macStudio
        }
        if name.contains("imac") || identifier.contains("imac") {
            return .iMac
        }
        if name.contains("mac pro") || identifier.contains("macpro") {
            return .macPro
        }
        return .mac
    }

    var symbolName: String {
        switch self {
        case .macBook: "macbook"
        case .macMini: "macmini"
        case .macStudio: "macstudio"
        case .iMac: "desktopcomputer"
        case .macPro: "macpro.gen3"
        case .mac: "desktopcomputer"
        }
    }
}
