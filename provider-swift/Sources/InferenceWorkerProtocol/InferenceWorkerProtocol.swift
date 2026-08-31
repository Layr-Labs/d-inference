import Foundation

public enum InferenceWorkerContract {
    public static let version: UInt16 = 2
    public static let machServiceName = "io.darkbloom.provider.inference-worker"
    public static let hostBundleIdentifier = "io.darkbloom.provider"
    public static let workerBundleIdentifier = "io.darkbloom.provider.inference-worker"
    public static let teamIdentifier = "SLDQ2GJ6TL"
    public static let executableName = "darkbloom-inference-worker"
    public static let xpcBundleName = "DarkbloomInferenceWorker.xpc"
    public static let relativeExecutablePath =
        "Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/darkbloom-inference-worker"
    public static let relativeBundlePathInsideApp =
        "Contents/XPCServices/DarkbloomInferenceWorker.xpc"
    public static let relativeExecutablePathInsideApp =
        "Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/darkbloom-inference-worker"
    public static let relativeMetallibPathInsideApp =
        "Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/mlx.metallib"
    public static let relativeResourcesPathInsideApp =
        "Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/Resources"
    public static let maximumRequestBytes = 24 * 1024 * 1024
    public static let maximumAggregateRequestBytes = 96 * 1024 * 1024
    public static let maximumResponseFrameBytes = 512 * 1024
    public static let maximumAggregateResponseBytes = 32 * 1024 * 1024
    public static let maximumMetadataBytes = 256 * 1024
    public static let maximumCatalogBytes = 4 * 1024 * 1024
    public static let maximumConcurrentRequests = 64
    public static let maximumPrivateV2Chunks = 8_192
    public static let maximumFramesPerRequest = maximumPrivateV2Chunks + 2
    public static let acknowledgementWindow = 8
    public static let maximumModels = 64
    public static let maximumIdentifierBytes = 256
    public static let maximumBookmarkBytes = 1024 * 1024

    public static let hostDesignatedRequirement =
        "anchor apple generic and identifier \"io.darkbloom.provider\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
    public static let workerDesignatedRequirement =
        "anchor apple generic and identifier \"io.darkbloom.provider.inference-worker\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
}

public enum InferenceWorkerErrorCode: Int, Sendable {
    case none = 0
    case incompatibleVersion = 1
    case invalidPeer = 2
    case invalidRequest = 3
    case requestTooLarge = 4
    case capacity = 5
    case notConfigured = 6
    case duplicateRequest = 7
    case backpressure = 8
    case cancelled = 9
    case execution = 10
    case modelArtifact = 11
    case terminalAlreadySent = 12
    case connectionInvalidated = 13
}

public enum WorkerRequestKind: Int, Sendable {
    case legacy = 1
    case privateV2 = 2
}

public enum WorkerFrameKind: Int, Sendable {
    case accepted = 1
    case legacyEncryptedChunk = 2
    case privateV2EncryptedChunk = 3
    case terminal = 4
}

public enum WorkerEventCode: Int, Sendable {
    case launch = 1
    case configured = 2
    case requestAccepted = 3
    case requestCancelled = 4
    case requestCompleted = 5
    case modelLoadStarted = 6
    case modelLoadCompleted = 7
    case modelUnloadCompleted = 8
    case capacityChanged = 9
    case peerRejected = 10
    case sandboxSelfTest = 11
}

public enum WorkerSandboxProbe: Int, Sendable {
    case networkClient = 0
    case networkServer = 1
    case arbitraryRead = 2
    case arbitraryWrite = 3
    case childProcess = 4
    case debugger = 5
}

private func boundedString(_ value: String, maximum: Int = InferenceWorkerContract.maximumIdentifierBytes) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
}

public final class WorkerHandshakeRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let challenge: Data

    public init?(version: UInt16 = InferenceWorkerContract.version, challenge: Data) {
        guard (16...64).contains(challenge.count) else { return nil }
        self.version = version
        self.challenge = challenge
    }

    public required init?(coder: NSCoder) {
        let version = UInt16(clamping: coder.decodeInteger(forKey: "version"))
        guard let challenge = coder.decodeObject(of: NSData.self, forKey: "challenge") as? Data,
              (16...64).contains(challenge.count) else { return nil }
        self.version = version
        self.challenge = challenge
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(challenge as NSData, forKey: "challenge")
    }
}

public final class WorkerHandshakeResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let challenge: Data
    public let launchIdentifier: String
    public let processPublicKey: Data
    public let processIdentifier: Int32
    public let workerBinarySHA256: String?
    public let metallibSHA256: String?
    public let runtimeCapabilitiesJSON: Data

    public init?(
        version: UInt16,
        challenge: Data,
        launchIdentifier: String,
        processPublicKey: Data,
        processIdentifier: Int32,
        workerBinarySHA256: String? = nil,
        metallibSHA256: String? = nil,
        runtimeCapabilitiesJSON: Data = Data("[]".utf8)
    ) {
        guard version == InferenceWorkerContract.version,
              (16...64).contains(challenge.count),
              boundedString(launchIdentifier),
              processPublicKey.count == 32,
              processIdentifier > 0,
              workerBinarySHA256 == nil || workerBinarySHA256?.count == 64,
              metallibSHA256 == nil || metallibSHA256?.count == 64,
              runtimeCapabilitiesJSON.count
                <= InferenceWorkerContract.maximumMetadataBytes
        else { return nil }
        self.version = version
        self.challenge = challenge
        self.launchIdentifier = launchIdentifier
        self.processPublicKey = processPublicKey
        self.processIdentifier = processIdentifier
        self.workerBinarySHA256 = workerBinarySHA256
        self.metallibSHA256 = metallibSHA256
        self.runtimeCapabilitiesJSON = runtimeCapabilitiesJSON
    }

    public required init?(coder: NSCoder) {
        let version = UInt16(clamping: coder.decodeInteger(forKey: "version"))
        guard version == InferenceWorkerContract.version,
              let challenge = coder.decodeObject(
                of: NSData.self, forKey: "challenge") as? Data,
              let launchIdentifier = coder.decodeObject(
                of: NSString.self, forKey: "launch") as? String,
              let processPublicKey = coder.decodeObject(
                of: NSData.self, forKey: "publicKey") as? Data
        else { return nil }
        let runtimeCapabilitiesJSON = coder.decodeObject(
            of: NSData.self, forKey: "runtimeCapabilities") as? Data
            ?? Data("[]".utf8)
        guard let validated = WorkerHandshakeResponse(
            version: version,
            challenge: challenge,
            launchIdentifier: launchIdentifier,
            processPublicKey: processPublicKey,
            processIdentifier:
                Int32(clamping: coder.decodeInteger(forKey: "pid")),
            workerBinarySHA256: coder.decodeObject(
                of: NSString.self, forKey: "binaryHash") as? String,
            metallibSHA256: coder.decodeObject(
                of: NSString.self, forKey: "metallibHash") as? String,
            runtimeCapabilitiesJSON: runtimeCapabilitiesJSON)
        else { return nil }
        self.version = validated.version
        self.challenge = validated.challenge
        self.launchIdentifier = validated.launchIdentifier
        self.processPublicKey = validated.processPublicKey
        self.processIdentifier = validated.processIdentifier
        self.workerBinarySHA256 = validated.workerBinarySHA256
        self.metallibSHA256 = validated.metallibSHA256
        self.runtimeCapabilitiesJSON = validated.runtimeCapabilitiesJSON
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(challenge as NSData, forKey: "challenge")
        coder.encode(launchIdentifier as NSString, forKey: "launch")
        coder.encode(processPublicKey as NSData, forKey: "publicKey")
        coder.encode(Int(processIdentifier), forKey: "pid")
        if let workerBinarySHA256 {
            coder.encode(workerBinarySHA256 as NSString, forKey: "binaryHash")
        }
        if let metallibSHA256 {
            coder.encode(metallibSHA256 as NSString, forKey: "metallibHash")
        }
        coder.encode(
            runtimeCapabilitiesJSON as NSData,
            forKey: "runtimeCapabilities")
    }
}

public final class WorkerModelArtifactDescriptor: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let modelIdentifier: String
    public let canonicalPath: String
    public let manifestSHA256: String
    public let bookmark: Data
    public let byteCount: UInt64

    public init?(modelIdentifier: String, canonicalPath: String, manifestSHA256: String, bookmark: Data, byteCount: UInt64) {
        guard boundedString(modelIdentifier), boundedString(canonicalPath, maximum: 4096),
              manifestSHA256.count == 64,
              manifestSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !bookmark.isEmpty, bookmark.count <= InferenceWorkerContract.maximumBookmarkBytes,
              byteCount > 0 else { return nil }
        self.modelIdentifier = modelIdentifier
        self.canonicalPath = canonicalPath
        self.manifestSHA256 = manifestSHA256
        self.bookmark = bookmark
        self.byteCount = byteCount
    }

    public required init?(coder: NSCoder) {
        guard let modelIdentifier = coder.decodeObject(of: NSString.self, forKey: "model") as? String,
              let canonicalPath = coder.decodeObject(of: NSString.self, forKey: "path") as? String,
              let hash = coder.decodeObject(of: NSString.self, forKey: "hash") as? String,
              let bookmark = coder.decodeObject(of: NSData.self, forKey: "bookmark") as? Data else { return nil }
        self.byteCount = UInt64(coder.decodeInt64(forKey: "bytes"))
        guard let validated = WorkerModelArtifactDescriptor(
            modelIdentifier: modelIdentifier, canonicalPath: canonicalPath,
            manifestSHA256: hash, bookmark: bookmark, byteCount: byteCount) else { return nil }
        self.modelIdentifier = validated.modelIdentifier
        self.canonicalPath = validated.canonicalPath
        self.manifestSHA256 = validated.manifestSHA256
        self.bookmark = validated.bookmark
    }

    public func encode(with coder: NSCoder) {
        coder.encode(modelIdentifier as NSString, forKey: "model")
        coder.encode(canonicalPath as NSString, forKey: "path")
        coder.encode(manifestSHA256 as NSString, forKey: "hash")
        coder.encode(bookmark as NSData, forKey: "bookmark")
        coder.encode(Int64(clamping: byteCount), forKey: "bytes")
    }
}

public final class WorkerBootstrapConfiguration: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let modelCatalogJSON: Data
    public let runtimeCapabilitiesJSON: Data
    public let inferenceConfigurationJSON: Data
    public let artifacts: [WorkerModelArtifactDescriptor]
    public let releaseBinaryHash: String
    public let releaseGeneration: UInt64
    public let modelGeneration: UInt64
    public let privateCacheLimitBytes: UInt64
    public let idleTimeoutMinutes: UInt64

    public init?(version: UInt16 = InferenceWorkerContract.version, modelCatalogJSON: Data,
                 runtimeCapabilitiesJSON: Data = Data("[]".utf8),
                 inferenceConfigurationJSON: Data = Data("{}".utf8),
                 artifacts: [WorkerModelArtifactDescriptor], releaseBinaryHash: String,
                 releaseGeneration: UInt64, modelGeneration: UInt64,
                 privateCacheLimitBytes: UInt64,
                 idleTimeoutMinutes: UInt64 = 0) {
        guard version == InferenceWorkerContract.version,
              modelCatalogJSON.count <= InferenceWorkerContract.maximumCatalogBytes,
              runtimeCapabilitiesJSON.count <= InferenceWorkerContract.maximumMetadataBytes,
              inferenceConfigurationJSON.count <= InferenceWorkerContract.maximumMetadataBytes,
              artifacts.count <= InferenceWorkerContract.maximumModels,
              Set(artifacts.map(\.modelIdentifier)).count == artifacts.count,
              releaseBinaryHash.count == 64,
              privateCacheLimitBytes > 0, privateCacheLimitBytes <= 32 * 1024 * 1024 * 1024 else { return nil }
        self.version = version
        self.modelCatalogJSON = modelCatalogJSON
        self.runtimeCapabilitiesJSON = runtimeCapabilitiesJSON
        self.inferenceConfigurationJSON = inferenceConfigurationJSON
        self.artifacts = artifacts
        self.releaseBinaryHash = releaseBinaryHash
        self.releaseGeneration = releaseGeneration
        self.modelGeneration = modelGeneration
        self.privateCacheLimitBytes = privateCacheLimitBytes
        self.idleTimeoutMinutes = idleTimeoutMinutes
    }

    public required init?(coder: NSCoder) {
        let classes: [AnyClass] = [NSArray.self, WorkerModelArtifactDescriptor.self]
        let runtimeCapabilities = coder.decodeObject(
            of: NSData.self, forKey: "runtimeCapabilities") as? Data
            ?? Data("[]".utf8)
        let inferenceConfiguration = coder.decodeObject(
            of: NSData.self, forKey: "inferenceConfiguration") as? Data
            ?? Data("{}".utf8)
        guard let catalog = coder.decodeObject(
                of: NSData.self, forKey: "catalog") as? Data,
              let artifacts = coder.decodeObject(
                of: classes, forKey: "artifacts") as? [WorkerModelArtifactDescriptor],
              let releaseHash = coder.decodeObject(
                of: NSString.self, forKey: "releaseHash") as? String,
              let validated = WorkerBootstrapConfiguration(
                version: UInt16(clamping: coder.decodeInteger(forKey: "version")),
                modelCatalogJSON: catalog,
                runtimeCapabilitiesJSON: runtimeCapabilities,
                inferenceConfigurationJSON: inferenceConfiguration,
                artifacts: artifacts,
                releaseBinaryHash: releaseHash,
                releaseGeneration: UInt64(coder.decodeInt64(forKey: "releaseGeneration")),
                modelGeneration: UInt64(coder.decodeInt64(forKey: "modelGeneration")),
                privateCacheLimitBytes: UInt64(coder.decodeInt64(forKey: "cacheLimit")),
                idleTimeoutMinutes: UInt64(coder.decodeInt64(forKey: "idleTimeoutMinutes")))
        else { return nil }
        self.version = validated.version
        self.modelCatalogJSON = validated.modelCatalogJSON
        self.runtimeCapabilitiesJSON = validated.runtimeCapabilitiesJSON
        self.inferenceConfigurationJSON = validated.inferenceConfigurationJSON
        self.artifacts = validated.artifacts
        self.releaseBinaryHash = validated.releaseBinaryHash
        self.idleTimeoutMinutes = validated.idleTimeoutMinutes
        self.releaseGeneration = validated.releaseGeneration
        self.modelGeneration = validated.modelGeneration
        self.privateCacheLimitBytes = validated.privateCacheLimitBytes
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(modelCatalogJSON as NSData, forKey: "catalog")
        coder.encode(runtimeCapabilitiesJSON as NSData, forKey: "runtimeCapabilities")
        coder.encode(
            inferenceConfigurationJSON as NSData,
            forKey: "inferenceConfiguration")
        coder.encode(artifacts as NSArray, forKey: "artifacts")
        coder.encode(releaseBinaryHash as NSString, forKey: "releaseHash")
        coder.encode(Int64(clamping: releaseGeneration), forKey: "releaseGeneration")
        coder.encode(Int64(clamping: modelGeneration), forKey: "modelGeneration")
        coder.encode(Int64(clamping: privateCacheLimitBytes), forKey: "cacheLimit")
        coder.encode(Int64(clamping: idleTimeoutMinutes), forKey: "idleTimeoutMinutes")
    }
}

public final class WorkerBootstrapResult: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let acceptedModelIdentifiers: [String]
    public let runtimeCapabilitiesJSON: Data

    public init?(
        version: UInt16 = InferenceWorkerContract.version,
        acceptedModelIdentifiers: [String],
        runtimeCapabilitiesJSON: Data
    ) {
        guard version == InferenceWorkerContract.version,
              acceptedModelIdentifiers.count
                <= InferenceWorkerContract.maximumModels,
              Set(acceptedModelIdentifiers).count
                == acceptedModelIdentifiers.count,
              acceptedModelIdentifiers.allSatisfy({ boundedString($0) }),
              runtimeCapabilitiesJSON.count
                <= InferenceWorkerContract.maximumMetadataBytes
        else { return nil }
        self.version = version
        self.acceptedModelIdentifiers = acceptedModelIdentifiers
        self.runtimeCapabilitiesJSON = runtimeCapabilitiesJSON
    }

    public required init?(coder: NSCoder) {
        let classes: [AnyClass] = [NSArray.self, NSString.self]
        guard let identifiers = coder.decodeObject(
                of: classes, forKey: "models") as? [String],
              let capabilities = coder.decodeObject(
                of: NSData.self, forKey: "capabilities") as? Data,
              let validated = WorkerBootstrapResult(
                version: UInt16(
                    clamping: coder.decodeInteger(forKey: "version")),
                acceptedModelIdentifiers: identifiers,
                runtimeCapabilitiesJSON: capabilities)
        else { return nil }
        self.version = validated.version
        self.acceptedModelIdentifiers = validated.acceptedModelIdentifiers
        self.runtimeCapabilitiesJSON = validated.runtimeCapabilitiesJSON
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(acceptedModelIdentifiers as NSArray, forKey: "models")
        coder.encode(
            runtimeCapabilitiesJSON as NSData,
            forKey: "capabilities")
    }
}

public final class WorkerInferenceRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let kindRawValue: Int
    public let requestIdentifier: String
    public let envelope: Data
    public let senderPublicKey: Data?
    public let authenticatedMetadataJSON: Data?
    public let firstContentDeadlineUptimeNanoseconds: UInt64

    public var kind: WorkerRequestKind? { WorkerRequestKind(rawValue: kindRawValue) }

    public init?(version: UInt16 = InferenceWorkerContract.version, kind: WorkerRequestKind,
                 requestIdentifier: String, envelope: Data, senderPublicKey: Data?,
                 authenticatedMetadataJSON: Data?,
                 firstContentDeadlineUptimeNanoseconds: UInt64 = 0) {
        guard version == InferenceWorkerContract.version, boundedString(requestIdentifier),
              !envelope.isEmpty, envelope.count <= InferenceWorkerContract.maximumRequestBytes,
              senderPublicKey == nil || senderPublicKey?.count == 32,
              authenticatedMetadataJSON == nil || authenticatedMetadataJSON!.count <= InferenceWorkerContract.maximumMetadataBytes
        else { return nil }
        if kind == .legacy && senderPublicKey?.count != 32 { return nil }
        self.version = version
        self.kindRawValue = kind.rawValue
        self.requestIdentifier = requestIdentifier
        self.envelope = envelope
        self.senderPublicKey = senderPublicKey
        self.authenticatedMetadataJSON = authenticatedMetadataJSON
        self.firstContentDeadlineUptimeNanoseconds =
            firstContentDeadlineUptimeNanoseconds
    }

    public required init?(coder: NSCoder) {
        let kindRaw = coder.decodeInteger(forKey: "kind")
        let encodedDeadline = coder.decodeInt64(forKey: "deadline")
        guard encodedDeadline >= 0,
              let kind = WorkerRequestKind(rawValue: kindRaw),
              let requestIdentifier = coder.decodeObject(of: NSString.self, forKey: "request") as? String,
              let envelope = coder.decodeObject(of: NSData.self, forKey: "envelope") as? Data,
              let validated = WorkerInferenceRequest(
                version: UInt16(clamping: coder.decodeInteger(forKey: "version")), kind: kind,
                requestIdentifier: requestIdentifier, envelope: envelope,
                senderPublicKey: coder.decodeObject(of: NSData.self, forKey: "senderKey") as? Data,
                authenticatedMetadataJSON: coder.decodeObject(of: NSData.self, forKey: "metadata") as? Data,
                firstContentDeadlineUptimeNanoseconds:
                    UInt64(encodedDeadline)) else { return nil }
        self.version = validated.version
        self.kindRawValue = validated.kindRawValue
        self.requestIdentifier = validated.requestIdentifier
        self.envelope = validated.envelope
        self.senderPublicKey = validated.senderPublicKey
        self.authenticatedMetadataJSON = validated.authenticatedMetadataJSON
        self.firstContentDeadlineUptimeNanoseconds =
            validated.firstContentDeadlineUptimeNanoseconds
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(kindRawValue, forKey: "kind")
        coder.encode(requestIdentifier as NSString, forKey: "request")
        coder.encode(envelope as NSData, forKey: "envelope")
        if let senderPublicKey { coder.encode(senderPublicKey as NSData, forKey: "senderKey") }
        if let authenticatedMetadataJSON { coder.encode(authenticatedMetadataJSON as NSData, forKey: "metadata") }
        coder.encode(
            Int64(clamping: firstContentDeadlineUptimeNanoseconds),
            forKey: "deadline")
    }
}

public final class WorkerResponseFrame: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let kindRawValue: Int
    public let requestIdentifier: String
    public let sequence: UInt64
    public let payload: Data
    public let ephemeralPublicKey: Data?
    public let promptTokens: UInt64
    public let completionTokens: UInt64
    public let failureCode: Int
    public let statusCode: UInt16
    public let responseHash: String?
    public let attestationSignature: String?
    public let resultMetadataJSON: Data?
    public let terminal: Bool

    public var kind: WorkerFrameKind? { WorkerFrameKind(rawValue: kindRawValue) }

    public init?(version: UInt16 = InferenceWorkerContract.version, kind: WorkerFrameKind,
                 requestIdentifier: String, sequence: UInt64, payload: Data = Data(),
                 ephemeralPublicKey: Data? = nil, promptTokens: UInt64 = 0,
                 completionTokens: UInt64 = 0, failureCode: Int = 0,
                 statusCode: UInt16 = 0, responseHash: String? = nil,
                 attestationSignature: String? = nil,
                 resultMetadataJSON: Data? = nil, terminal: Bool) {
        let validTerminalShape =
            (kind == .terminal && terminal)
            || (kind == .privateV2EncryptedChunk)
            || ((kind == .accepted || kind == .legacyEncryptedChunk) && !terminal)
        guard version == InferenceWorkerContract.version, boundedString(requestIdentifier),
              sequence < UInt64(InferenceWorkerContract.maximumFramesPerRequest),
              payload.count <= InferenceWorkerContract.maximumResponseFrameBytes,
              ephemeralPublicKey == nil || ephemeralPublicKey?.count == 32,
              responseHash == nil || (
                responseHash?.count == 64
                && responseHash!.allSatisfy { $0.isHexDigit && !$0.isUppercase }),
              attestationSignature == nil
                || attestationSignature!.utf8.count <= 1024,
              resultMetadataJSON == nil
                || resultMetadataJSON!.count <= InferenceWorkerContract.maximumMetadataBytes,
              validTerminalShape else { return nil }
        self.version = version
        self.kindRawValue = kind.rawValue
        self.requestIdentifier = requestIdentifier
        self.sequence = sequence
        self.payload = payload
        self.ephemeralPublicKey = ephemeralPublicKey
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.failureCode = failureCode
        self.statusCode = statusCode
        self.responseHash = responseHash
        self.attestationSignature = attestationSignature
        self.resultMetadataJSON = resultMetadataJSON
        self.terminal = terminal
    }

    public required init?(coder: NSCoder) {
        guard let kind = WorkerFrameKind(rawValue: coder.decodeInteger(forKey: "kind")),
              let requestIdentifier = coder.decodeObject(of: NSString.self, forKey: "request") as? String,
              let payload = coder.decodeObject(of: NSData.self, forKey: "payload") as? Data,
              let validated = WorkerResponseFrame(
                version: UInt16(clamping: coder.decodeInteger(forKey: "version")), kind: kind,
                requestIdentifier: requestIdentifier, sequence: UInt64(coder.decodeInt64(forKey: "sequence")),
                payload: payload,
                ephemeralPublicKey: coder.decodeObject(of: NSData.self, forKey: "ephemeralKey") as? Data,
                promptTokens: UInt64(coder.decodeInt64(forKey: "promptTokens")),
                completionTokens: UInt64(coder.decodeInt64(forKey: "completionTokens")),
                failureCode: coder.decodeInteger(forKey: "failure"),
                statusCode: UInt16(clamping: coder.decodeInteger(forKey: "status")),
                responseHash: coder.decodeObject(
                    of: NSString.self, forKey: "responseHash") as? String,
                attestationSignature: coder.decodeObject(
                    of: NSString.self, forKey: "attestationSignature") as? String,
                resultMetadataJSON: coder.decodeObject(
                    of: NSData.self, forKey: "resultMetadata") as? Data,
                terminal: coder.decodeBool(forKey: "terminal")) else { return nil }
        self.version = validated.version
        self.kindRawValue = validated.kindRawValue
        self.requestIdentifier = validated.requestIdentifier
        self.sequence = validated.sequence
        self.payload = validated.payload
        self.ephemeralPublicKey = validated.ephemeralPublicKey
        self.promptTokens = validated.promptTokens
        self.completionTokens = validated.completionTokens
        self.failureCode = validated.failureCode
        self.statusCode = validated.statusCode
        self.responseHash = validated.responseHash
        self.attestationSignature = validated.attestationSignature
        self.resultMetadataJSON = validated.resultMetadataJSON
        self.terminal = validated.terminal
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(kindRawValue, forKey: "kind")
        coder.encode(requestIdentifier as NSString, forKey: "request")
        coder.encode(Int64(clamping: sequence), forKey: "sequence")
        coder.encode(payload as NSData, forKey: "payload")
        if let ephemeralPublicKey { coder.encode(ephemeralPublicKey as NSData, forKey: "ephemeralKey") }
        coder.encode(Int64(clamping: promptTokens), forKey: "promptTokens")
        coder.encode(Int64(clamping: completionTokens), forKey: "completionTokens")
        coder.encode(failureCode, forKey: "failure")
        coder.encode(Int(statusCode), forKey: "status")
        if let responseHash {
            coder.encode(responseHash as NSString, forKey: "responseHash")
        }
        if let attestationSignature {
            coder.encode(
                attestationSignature as NSString,
                forKey: "attestationSignature")
        }
        if let resultMetadataJSON {
            coder.encode(resultMetadataJSON as NSData, forKey: "resultMetadata")
        }
        coder.encode(terminal, forKey: "terminal")
    }
}

public final class WorkerFrameAcknowledgement: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let requestIdentifier: String
    public let sequence: UInt64

    public init?(requestIdentifier: String, sequence: UInt64) {
        guard boundedString(requestIdentifier), sequence < UInt64(InferenceWorkerContract.maximumFramesPerRequest) else { return nil }
        self.requestIdentifier = requestIdentifier
        self.sequence = sequence
    }

    public required init?(coder: NSCoder) {
        guard let requestIdentifier = coder.decodeObject(of: NSString.self, forKey: "request") as? String,
              let validated = WorkerFrameAcknowledgement(
                requestIdentifier: requestIdentifier,
                sequence: UInt64(coder.decodeInt64(forKey: "sequence"))) else { return nil }
        self.requestIdentifier = validated.requestIdentifier
        self.sequence = validated.sequence
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestIdentifier as NSString, forKey: "request")
        coder.encode(Int64(clamping: sequence), forKey: "sequence")
    }
}

public final class WorkerCapacityEntry: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let modelIdentifier: String
    public let state: Int
    public let activeRequests: UInt16
    public let queuedRequests: UInt16
    public let maximumRequests: UInt16
    public let desiredGeneration: UInt64
    public let mtpState: Int
    public let kvBytes: UInt64
    public let capacityJSON: Data?
    public let manifestSHA256: String?
    public let mtpModelIdentifier: String?

    public init?(modelIdentifier: String, state: Int, activeRequests: UInt16,
                 queuedRequests: UInt16, maximumRequests: UInt16,
                 desiredGeneration: UInt64, mtpState: Int, kvBytes: UInt64,
                 capacityJSON: Data? = nil, manifestSHA256: String? = nil,
                 mtpModelIdentifier: String? = nil) {
        guard boundedString(modelIdentifier), activeRequests <= maximumRequests,
              maximumRequests <= UInt16(InferenceWorkerContract.maximumConcurrentRequests),
              capacityJSON == nil || capacityJSON!.count <= 64 * 1024,
              manifestSHA256 == nil || manifestSHA256?.count == 64,
              mtpModelIdentifier == nil || boundedString(mtpModelIdentifier!) else {
            return nil
        }
        self.modelIdentifier = modelIdentifier
        self.state = state
        self.activeRequests = activeRequests
        self.queuedRequests = queuedRequests
        self.maximumRequests = maximumRequests
        self.desiredGeneration = desiredGeneration
        self.mtpState = mtpState
        self.kvBytes = kvBytes
        self.capacityJSON = capacityJSON
        self.manifestSHA256 = manifestSHA256
        self.mtpModelIdentifier = mtpModelIdentifier
    }

    public required init?(coder: NSCoder) {
        guard let model = coder.decodeObject(of: NSString.self, forKey: "model") as? String,
              let validated = WorkerCapacityEntry(
                modelIdentifier: model, state: coder.decodeInteger(forKey: "state"),
                activeRequests: UInt16(clamping: coder.decodeInteger(forKey: "active")),
                queuedRequests: UInt16(clamping: coder.decodeInteger(forKey: "queued")),
                maximumRequests: UInt16(clamping: coder.decodeInteger(forKey: "maximum")),
                desiredGeneration: UInt64(coder.decodeInt64(forKey: "generation")),
                mtpState: coder.decodeInteger(forKey: "mtp"),
                kvBytes: UInt64(coder.decodeInt64(forKey: "kv")),
                capacityJSON: coder.decodeObject(of: NSData.self, forKey: "capacity") as? Data,
                manifestSHA256: coder.decodeObject(of: NSString.self, forKey: "manifest") as? String,
                mtpModelIdentifier: coder.decodeObject(of: NSString.self, forKey: "mtpModel") as? String)
        else { return nil }
        self.modelIdentifier = validated.modelIdentifier
        self.state = validated.state
        self.activeRequests = validated.activeRequests
        self.queuedRequests = validated.queuedRequests
        self.maximumRequests = validated.maximumRequests
        self.desiredGeneration = validated.desiredGeneration
        self.mtpState = validated.mtpState
        self.kvBytes = validated.kvBytes
        self.capacityJSON = validated.capacityJSON
        self.manifestSHA256 = validated.manifestSHA256
        self.mtpModelIdentifier = validated.mtpModelIdentifier
    }

    public func encode(with coder: NSCoder) {
        coder.encode(modelIdentifier as NSString, forKey: "model")
        coder.encode(state, forKey: "state")
        coder.encode(Int(activeRequests), forKey: "active")
        coder.encode(Int(queuedRequests), forKey: "queued")
        coder.encode(Int(maximumRequests), forKey: "maximum")
        coder.encode(Int64(clamping: desiredGeneration), forKey: "generation")
        coder.encode(mtpState, forKey: "mtp")
        coder.encode(Int64(clamping: kvBytes), forKey: "kv")
        if let capacityJSON { coder.encode(capacityJSON as NSData, forKey: "capacity") }
        if let manifestSHA256 {
            coder.encode(manifestSHA256 as NSString, forKey: "manifest")
        }
        if let mtpModelIdentifier {
            coder.encode(mtpModelIdentifier as NSString, forKey: "mtpModel")
        }
    }
}

public final class WorkerCapacitySnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let launchIdentifier: String
    public let sequence: UInt64
    public let entries: [WorkerCapacityEntry]
    public let gpuActiveBytes: UInt64
    public let gpuPeakBytes: UInt64
    public let gpuCacheBytes: UInt64
    public let totalMemoryBytes: UInt64
    public let freeForLoadBytes: UInt64
    public let prefixCacheAdvertisementJSON: Data?

    public init?(version: UInt16 = InferenceWorkerContract.version, launchIdentifier: String,
                 sequence: UInt64, entries: [WorkerCapacityEntry],
                 gpuActiveBytes: UInt64 = 0, gpuPeakBytes: UInt64 = 0,
                 gpuCacheBytes: UInt64 = 0, totalMemoryBytes: UInt64 = 0,
                 freeForLoadBytes: UInt64 = 0,
                 prefixCacheAdvertisementJSON: Data? = nil) {
        guard version == InferenceWorkerContract.version, boundedString(launchIdentifier),
              entries.count <= InferenceWorkerContract.maximumModels,
              prefixCacheAdvertisementJSON?.count ?? 0 <= InferenceWorkerContract.maximumMetadataBytes
        else { return nil }
        self.version = version
        self.launchIdentifier = launchIdentifier
        self.sequence = sequence
        self.entries = entries
        self.gpuActiveBytes = gpuActiveBytes
        self.gpuPeakBytes = gpuPeakBytes
        self.gpuCacheBytes = gpuCacheBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.freeForLoadBytes = freeForLoadBytes
        self.prefixCacheAdvertisementJSON = prefixCacheAdvertisementJSON
    }

    public required init?(coder: NSCoder) {
        let classes: [AnyClass] = [NSArray.self, WorkerCapacityEntry.self]
        guard let launch = coder.decodeObject(of: NSString.self, forKey: "launch") as? String,
              let entries = coder.decodeObject(of: classes, forKey: "entries") as? [WorkerCapacityEntry],
              let validated = WorkerCapacitySnapshot(
                version: UInt16(clamping: coder.decodeInteger(forKey: "version")),
                launchIdentifier: launch, sequence: UInt64(coder.decodeInt64(forKey: "sequence")),
                entries: entries,
                gpuActiveBytes: UInt64(coder.decodeInt64(forKey: "gpuActive")),
                gpuPeakBytes: UInt64(coder.decodeInt64(forKey: "gpuPeak")),
                gpuCacheBytes: UInt64(coder.decodeInt64(forKey: "gpuCache")),
                totalMemoryBytes: UInt64(coder.decodeInt64(forKey: "totalMemory")),
                freeForLoadBytes: UInt64(coder.decodeInt64(forKey: "freeForLoad")),
                prefixCacheAdvertisementJSON:
                    coder.decodeObject(of: NSData.self, forKey: "prefixCache") as? Data)
        else { return nil }
        self.version = validated.version
        self.launchIdentifier = validated.launchIdentifier
        self.sequence = validated.sequence
        self.entries = validated.entries
        self.gpuActiveBytes = validated.gpuActiveBytes
        self.gpuPeakBytes = validated.gpuPeakBytes
        self.gpuCacheBytes = validated.gpuCacheBytes
        self.totalMemoryBytes = validated.totalMemoryBytes
        self.freeForLoadBytes = validated.freeForLoadBytes
        self.prefixCacheAdvertisementJSON = validated.prefixCacheAdvertisementJSON
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(launchIdentifier as NSString, forKey: "launch")
        coder.encode(Int64(clamping: sequence), forKey: "sequence")
        coder.encode(entries as NSArray, forKey: "entries")
        coder.encode(Int64(clamping: gpuActiveBytes), forKey: "gpuActive")
        coder.encode(Int64(clamping: gpuPeakBytes), forKey: "gpuPeak")
        coder.encode(Int64(clamping: gpuCacheBytes), forKey: "gpuCache")
        coder.encode(Int64(clamping: totalMemoryBytes), forKey: "totalMemory")
        coder.encode(Int64(clamping: freeForLoadBytes), forKey: "freeForLoad")
        if let prefixCacheAdvertisementJSON {
            coder.encode(prefixCacheAdvertisementJSON as NSData, forKey: "prefixCache")
        }
    }
}

public final class WorkerEvent: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let codeRawValue: Int
    public let value: Int64
    public let auxiliaryValue: Int64

    public init(code: WorkerEventCode, value: Int64 = 0, auxiliaryValue: Int64 = 0) {
        self.codeRawValue = code.rawValue
        self.value = value
        self.auxiliaryValue = auxiliaryValue
    }

    public required init?(coder: NSCoder) {
        let raw = coder.decodeInteger(forKey: "code")
        guard WorkerEventCode(rawValue: raw) != nil else { return nil }
        self.codeRawValue = raw
        self.value = coder.decodeInt64(forKey: "value")
        self.auxiliaryValue = coder.decodeInt64(forKey: "aux")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(codeRawValue, forKey: "code")
        coder.encode(value, forKey: "value")
        coder.encode(auxiliaryValue, forKey: "aux")
    }
}

@objc public protocol InferenceWorkerXPCProtocol {
    func handshake(_ request: WorkerHandshakeRequest, withReply reply: @escaping (WorkerHandshakeResponse?, Int) -> Void)
    func configure(_ configuration: WorkerBootstrapConfiguration,
                   withReply reply: @escaping (WorkerBootstrapResult?, Int) -> Void)
    func certify(launchIdentifier: String, connectionGeneration: UInt64,
                 withReply reply: @escaping (Int) -> Void)
    func answerCodeChallenge(_ request: WorkerCodeChallengeRequest,
                             withReply reply: @escaping (WorkerCodeChallengeProof?, Int) -> Void)
    func begin(_ request: WorkerInferenceRequest, withReply reply: @escaping (Int) -> Void)
    func acknowledge(_ acknowledgement: WorkerFrameAcknowledgement)
    func cancel(requestIdentifier: String)
    func preloadModel(identifier: String, withReply reply: @escaping (Int) -> Void)
    func capacitySnapshot(withReply reply: @escaping (WorkerCapacitySnapshot?, Int) -> Void)
    func runSandboxSelfTest(version: Int, withReply reply: @escaping (UInt64, Int) -> Void)
}

@objc public protocol InferenceWorkerHostProtocol {
    func workerDidEmit(_ frame: WorkerResponseFrame)
    func workerDidEmitEvent(_ event: WorkerEvent)
}

public enum InferenceWorkerXPCInterfaces {
    public static func worker() -> NSXPCInterface {
        // Every object in the signatures is a final NSSecureCoding DTO. Nested
        // collections decode their own explicit class allowlists.
        NSXPCInterface(with: InferenceWorkerXPCProtocol.self)
    }

    public static func host() -> NSXPCInterface {
        NSXPCInterface(with: InferenceWorkerHostProtocol.self)
    }
}
