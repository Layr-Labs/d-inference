import Foundation

/// Testable message construction for the NWConnection-based coordinator
/// client. The client owns transport/reconnect concerns; this type owns the
/// wire messages it sends and receives.
public enum CoordinatorClientCodec {
    public static func registrationMessage(
        from config: CoordinatorClientConfig,
        models: [ModelInfo]? = nil,
        version: String = ProviderCore.version,
        privacyCapabilities: PrivacyCapabilities? = nil,
        apnsDeviceTokenOverride: String? = nil,
        modelWeightHashOverrides: [String: String] = [:],
        protocolCapabilities: ProtocolCapabilities? = nil,
        providerProcessGeneration: ProviderProcessGenerationID? = nil
    ) -> ProviderMessage {
        // A token that arrived after the config was built (APNs slow at startup)
        // overrides the config value so a reconnect re-registers WITH it.
        let effectiveToken = apnsDeviceTokenOverride ?? config.apnsDeviceToken
        let effectiveEnv =
            apnsDeviceTokenOverride != nil
            ? (config.apnsEnvironment ?? "production")
            : config.apnsEnvironment
        // Weight hashes refreshed after a model (re)load override the
        // daemon-start values so a reconnect registers with the hashes of the
        // weights actually on disk (the coordinator's per-model catalog filter
        // keys off models[].weight_hash).
        // The advertised set may be overridden on a reconnect (prefetch re-advertise);
        // weight-hash overrides are then patched on top of whichever set we send.
        let baseModels = models ?? config.models
        let effectiveModels: [ModelInfo]
        if modelWeightHashOverrides.isEmpty {
            effectiveModels = baseModels
        } else {
            effectiveModels = baseModels.map { model in
                var patched = model
                if let fresh = modelWeightHashOverrides[model.id] {
                    patched.weightHash = fresh
                }
                return patched
            }
        }
        return .register(
            ProviderMessage.Register(
            hardware: config.hardware,
            models: effectiveModels,
            backend: config.backendName,
            version: version,
            publicKey: config.publicKey,
            encryptedResponseChunks: true,
            walletAddress: config.walletAddress,
            attestation: config.attestation,
            authToken: config.authToken,
            pythonHash: config.runtimeHashes?.pythonHash,
            runtimeHash: config.runtimeHashes?.runtimeHash,
            templateHashes: config.runtimeHashes?.templateHashes ?? [:],
            privacyCapabilities: privacyCapabilities,
                protocolCapabilities: protocolCapabilities,
                providerProcessGeneration: providerProcessGeneration,
            privateOnly: config.privateOnly,
            apnsDeviceToken: effectiveToken,
            apnsEnvironment: effectiveEnv
        ))
    }

    public static func encodeRegistration(
        from config: CoordinatorClientConfig,
        models: [ModelInfo]? = nil,
        version: String = ProviderCore.version,
        privacyCapabilities: PrivacyCapabilities? = nil,
        apnsDeviceTokenOverride: String? = nil,
        modelWeightHashOverrides: [String: String] = [:],
        protocolCapabilities: ProtocolCapabilities? = nil,
        providerProcessGeneration: ProviderProcessGenerationID? = nil
    ) throws -> Data {
        try ProviderProtocolCodec.encodeProviderMessage(
            registrationMessage(
                from: config,
                models: models,
                version: version,
                privacyCapabilities: privacyCapabilities,
                apnsDeviceTokenOverride: apnsDeviceTokenOverride,
                modelWeightHashOverrides: modelWeightHashOverrides,
                protocolCapabilities: protocolCapabilities,
                providerProcessGeneration: providerProcessGeneration
            )
        )
    }

    public static func heartbeatMessage(
        status: ProviderStatus,
        activeModel: String?,
        warmModels: [String],
        stats: ProviderStats,
        systemMetrics: SystemMetrics,
        backendCapacity: BackendCapacity?,
        modelStateRevision: UInt64? = nil,
        apnsDeviceToken: String? = nil,
        apnsEnvironment: String? = nil
    ) -> ProviderMessage {
        .heartbeat(
            ProviderMessage.Heartbeat(
            status: status,
            activeModel: activeModel,
            warmModels: warmModels,
            stats: stats,
            systemMetrics: systemMetrics,
            backendCapacity: backendCapacity,
                modelStateRevision: modelStateRevision,
            apnsDeviceToken: apnsDeviceToken,
            apnsEnvironment: apnsEnvironment
        ))
    }

    public static func providerMessage(for outbound: OutboundMessage) -> ProviderMessage {
        switch outbound {
        case .inferenceAccepted(let requestId):
            return .inferenceAccepted(ProviderMessage.InferenceAccepted(requestId: requestId))

        case .inferenceChunk(let requestId, let data, let encryptedData):
            return .inferenceResponseChunk(
                ProviderMessage.InferenceResponseChunk(
                requestId: requestId,
                data: data,
                encryptedData: encryptedData
            ))

        case .inferenceComplete(let requestId, let usage, let seSignature, let responseHash):
            return .inferenceComplete(
                ProviderMessage.InferenceComplete(
                requestId: requestId,
                usage: usage,
                seSignature: seSignature,
                responseHash: responseHash
            ))

        case .inferenceError(let requestId, let error, let statusCode, let errorReason):
            return .inferenceError(
                ProviderMessage.InferenceError(
                requestId: requestId,
                error: error,
                statusCode: statusCode,
                errorReason: errorReason
            ))

        case .attestationResponse(let payload):
            return .attestationResponse(
                ProviderMessage.AttestationResponse(
                nonce: payload.nonce,
                signature: payload.signature,
                statusSignature: payload.statusSignature,
                publicKey: payload.publicKey,
                rdmaDisabled: payload.rdmaDisabled,
                sipEnabled: payload.sipEnabled,
                secureBootEnabled: payload.secureBootEnabled,
                binaryHash: payload.binaryHash,
                activeModelHash: payload.activeModelHash,
                pythonHash: payload.pythonHash,
                runtimeHash: payload.runtimeHash,
                templateHashes: payload.templateHashes,
                modelHashes: payload.modelHashes
            ))

        case .codeAttestationResponse(let nonce, let signature):
            return .codeAttestationResponse(
                ProviderMessage.CodeAttestationResponse(
                nonce: nonce,
                signature: signature
            ))

        case .loadModelStatus(let modelId, let status, let error):
            return .loadModelStatus(
                ProviderMessage.LoadModelStatus(
                modelId: modelId,
                status: status,
                error: error
            ))

        case .prefetchModelStatus(let modelId, let status, let bytesDone, let bytesTotal, let error):
            return .prefetchModelStatus(
                ProviderMessage.PrefetchModelStatus(
                modelId: modelId,
                status: status,
                bytesDone: bytesDone,
                bytesTotal: bytesTotal,
                error: error
            ))

        case .modelsUpdate(let models):
            return .modelsUpdate(ProviderMessage.ModelsUpdate(models: models))

        case .prepared(let message):
            return .prepared(message)

        case .startAck(let message):
            return .startAck(message)

        case .abortAck(let message):
            return .abortAck(message)

        case .cancelAck(let message):
            return .cancelAck(message)

        case .providerTerminal(let message):
            return .providerTerminal(message)

        case .historicalProviderTerminal(let replay):
            return .providerTerminal(replay.terminal)

        case .structuredError(let message):
            return .structuredError(message)

        case .modelReady(let message):
            return .modelReady(message)

        case .modelGone(let message):
            return .modelGone(message)

        case .replayFenceAck(let message):
            return .replayFenceAck(message)
        }
    }

    public static func encodeOutboundMessage(_ outbound: OutboundMessage) throws -> Data {
        try ProviderProtocolCodec.encodeProviderMessage(providerMessage(for: outbound))
    }

    public static func encodeOutboundMessageString(_ outbound: OutboundMessage) throws -> String {
        try ProviderProtocolCodec.encodeProviderMessageString(providerMessage(for: outbound))
    }

    public static func decodeIncomingMessage(
        from data: Data,
        negotiatedV2Session: Bool = false
    ) throws -> CoordinatorMessage {
        try ProviderProtocolCodec.decodeCoordinatorMessage(
            from: data,
            negotiatedV2Session: negotiatedV2Session
        )
        }

    public static func decodeIncomingMessage(
        from string: String,
        negotiatedV2Session: Bool = false
    ) throws -> CoordinatorMessage {
        try ProviderProtocolCodec.decodeCoordinatorMessage(
            from: string,
            negotiatedV2Session: negotiatedV2Session
        )
    }

    public static func v2ControlMessage(
        from message: CoordinatorMessage
    ) -> V2CoordinatorControlMessage? {
        switch message {
        case .prepare(let value): .prepare(value)
        case .start(let value): .start(value)
        case .abort(let value): .abort(value)
        case .v2Cancel(let value): .cancel(value)
        case .terminalAck(let value): .terminalAck(value)
        case .coordinatorReplayFence(let value): .coordinatorReplayFence(value)
        default: nil
    }
    }

    public static func v2ControlMessage(
        from outbound: OutboundMessage
    ) -> V2ProviderControlMessage? {
        switch outbound {
        case .prepared(let value): .prepared(value)
        case .startAck(let value): .startAck(value)
        case .abortAck(let value): .abortAck(value)
        case .cancelAck(let value): .cancelAck(value)
        case .providerTerminal(let value): .terminal(value)
        case .historicalProviderTerminal(let replay): .terminal(replay.terminal)
        case .structuredError(let value): .structuredError(value)
        case .modelReady(let value): .modelReady(value)
        case .modelGone(let value): .modelGone(value)
        case .replayFenceAck(let value): .replayFenceAck(value)
        default: nil
        }
    }
}
