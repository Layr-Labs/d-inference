import Foundation

struct ModelSummary: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let family: String?
    let kind: ModelKind
    let summary: String
    let sizeBytes: Int64
    let minimumMemoryGB: Int?
    let quantization: String?
    let maxContextLength: Int?
    let capabilities: [ModelCapability]
    let origin: ModelOrigin
    var fit: ModelFit
    var installation: ModelInstallationState
    var runtime: ModelRuntimeState

    var isInstalled: Bool {
        if case .installed = installation { return true }
        return false
    }

    var isAvailableFromCatalog: Bool {
        origin == .catalog
    }
}

enum ModelKind: String, Hashable, Sendable {
    case text
    case vision
    case embeddings
    case unknown
}

struct ModelCapability: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let textGeneration = Self(rawValue: "text-generation")
    static let vision = Self(rawValue: "vision")
    static let tools = Self(rawValue: "tools")
    static let reasoning = Self(rawValue: "reasoning")
    static let embeddings = Self(rawValue: "embeddings")

    var displayName: String {
        switch self {
        case .textGeneration: "Text"
        case .vision: "Vision"
        case .tools: "Tools"
        case .reasoning: "Reasoning"
        case .embeddings: "Embeddings"
        default: rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

enum ModelOrigin: String, Hashable, Sendable {
    case catalog
    case retired
    case localOnly
}

enum ModelFit: Hashable, Sendable {
    case fits
    case tooLarge(requiredMemoryGB: Int, availableMemoryGB: Int)
    case unknown

    var canRunOnThisMac: Bool {
        if case .tooLarge = self { return false }
        return true
    }
}

enum ModelRuntimeState: String, Hashable, Sendable {
    case cold
    case loading
    case warm
    case serving
    case reloading
    case crashed
}

struct ModelTransferProgress: Hashable, Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Int64
    let estimatedSecondsRemaining: Int?
    let resumedBytes: Int64

    init(
        downloadedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Int64 = 0,
        estimatedSecondsRemaining: Int? = nil,
        resumedBytes: Int64 = 0
    ) {
        self.totalBytes = max(0, totalBytes)
        self.downloadedBytes = min(max(0, downloadedBytes), max(0, totalBytes))
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.estimatedSecondsRemaining = estimatedSecondsRemaining.map { max(0, $0) }
        self.resumedBytes = min(max(0, resumedBytes), self.downloadedBytes)
    }

    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    var isResumed: Bool {
        resumedBytes > 0
    }
}

enum ModelTransferFailureReason: String, Hashable, Sendable {
    case network
    case insufficientDiskSpace
    case verificationMismatch
    case unknown
}

struct ModelTransferFailure: Hashable, Sendable {
    let reason: ModelTransferFailureReason
    let message: String
    let resumableProgress: ModelTransferProgress?

    var isResumable: Bool {
        resumableProgress != nil && reason != .verificationMismatch
    }
}

enum ModelInstallationState: Hashable, Sendable {
    case notInstalled
    case downloading(ModelTransferProgress)
    case paused(ModelTransferProgress)
    case verifying(ModelTransferProgress)
    case installed
    case failed(ModelTransferFailure)

    var progress: ModelTransferProgress? {
        switch self {
        case .downloading(let progress), .paused(let progress), .verifying(let progress):
            progress
        case .failed(let failure):
            failure.resumableProgress
        case .notInstalled, .installed:
            nil
        }
    }
}
