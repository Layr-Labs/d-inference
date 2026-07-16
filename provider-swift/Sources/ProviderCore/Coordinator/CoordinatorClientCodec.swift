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
        prefixCacheProtocol: Int = 1,
        prefixCacheV2Models: [PrefixCacheV2Capability]? = nil
    ) -> ProviderMessage {
        // A token that arrived after the config was built (APNs slow at startup)
        // overrides the config value so a reconnect re-registers WITH it.
        let effectiveToken = apnsDeviceTokenOverride ?? config.apnsDeviceToken
        let effectiveEnv = apnsDeviceTokenOverride != nil
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
        return .register(ProviderMessage.Register(
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
            privateOnly: config.privateOnly,
            apnsDeviceToken: effectiveToken,
            apnsEnvironment: effectiveEnv,
            prefixCacheProtocol: prefixCacheProtocol,
            prefixCacheV2Models: prefixCacheV2Models
        ))
    }

    public static func encodeRegistration(
        from config: CoordinatorClientConfig,
        models: [ModelInfo]? = nil,
        version: String = ProviderCore.version,
        privacyCapabilities: PrivacyCapabilities? = nil,
        apnsDeviceTokenOverride: String? = nil,
        modelWeightHashOverrides: [String: String] = [:],
        prefixCacheProtocol: Int = 1,
        prefixCacheV2Models: [PrefixCacheV2Capability]? = nil
    ) throws -> Data {
        try ProviderProtocolCodec.encodeProviderMessage(
            registrationMessage(
                from: config,
                models: models,
                version: version,
                privacyCapabilities: privacyCapabilities,
                apnsDeviceTokenOverride: apnsDeviceTokenOverride,
                modelWeightHashOverrides: modelWeightHashOverrides,
                prefixCacheProtocol: prefixCacheProtocol,
                prefixCacheV2Models: prefixCacheV2Models
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
        apnsDeviceToken: String? = nil,
        apnsEnvironment: String? = nil,
        prefixCacheProtocol: Int? = nil,
        prefixCacheV2Models: [PrefixCacheV2Capability]? = nil
    ) -> ProviderMessage {
        .heartbeat(ProviderMessage.Heartbeat(
            status: status,
            activeModel: activeModel,
            warmModels: warmModels,
            stats: stats,
            systemMetrics: systemMetrics,
            backendCapacity: backendCapacity,
            apnsDeviceToken: apnsDeviceToken,
            apnsEnvironment: apnsEnvironment,
            prefixCacheProtocol: prefixCacheProtocol,
            prefixCacheV2Models: prefixCacheV2Models
        ))
    }

    public static func providerMessage(for outbound: OutboundMessage) -> ProviderMessage {
        switch outbound {
        case .inferenceAccepted(let requestId):
            return .inferenceAccepted(ProviderMessage.InferenceAccepted(requestId: requestId))

        case .inferenceChunk(let requestId, let data, let encryptedData):
            return .inferenceResponseChunk(ProviderMessage.InferenceResponseChunk(
                requestId: requestId,
                data: data,
                encryptedData: encryptedData
            ))

        case .inferenceComplete(let requestId, let usage, let seSignature, let responseHash):
            return .inferenceComplete(ProviderMessage.InferenceComplete(
                requestId: requestId,
                usage: usage,
                seSignature: seSignature,
                responseHash: responseHash
            ))

        case .inferenceError(let requestId, let error, let statusCode, let errorReason):
            return .inferenceError(ProviderMessage.InferenceError(
                requestId: requestId,
                error: error,
                statusCode: statusCode,
                errorReason: errorReason
            ))

        case .attestationResponse(let payload):
            return .attestationResponse(ProviderMessage.AttestationResponse(
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
            return .codeAttestationResponse(ProviderMessage.CodeAttestationResponse(
                nonce: nonce,
                signature: signature
            ))

        case .loadModelStatus(let modelId, let status, let error):
            return .loadModelStatus(ProviderMessage.LoadModelStatus(
                modelId: modelId,
                status: status,
                error: error
            ))

        case .prefetchModelStatus(let modelId, let status, let bytesDone, let bytesTotal, let error):
            return .prefetchModelStatus(ProviderMessage.PrefetchModelStatus(
                modelId: modelId,
                status: status,
                bytesDone: bytesDone,
                bytesTotal: bytesTotal,
                error: error
            ))

        case .modelsUpdate(let models):
            return .modelsUpdate(ProviderMessage.ModelsUpdate(models: models))

        case .prefixCacheLookup(
            let requestId, let nonce, let outcome, let tier,
            let cachedTokens, let prefillTokensSaved, let stageMs
        ):
            return .prefixCacheLookup(ProviderMessage.PrefixCacheLookup(
                requestId: requestId,
                cacheReceiptNonce: nonce,
                outcome: outcome,
                tier: tier,
                cachedTokens: cachedTokens,
                prefillTokensSaved: prefillTokensSaved,
                stageMs: stageMs
            ))

        case .prefixCacheReady(
            let requestId, let nonce, let readyTokens,
            let requiredRecomputeTokens, let expectedPrefillTokensSaved, let tier, let stageMs
        ):
            return .prefixCacheReady(ProviderMessage.PrefixCacheReady(
                requestId: requestId,
                cacheReceiptNonce: nonce,
                readyTokens: readyTokens,
                requiredRecomputeTokens: requiredRecomputeTokens,
                expectedPrefillTokensSaved: expectedPrefillTokensSaved,
                tier: tier,
                stageMs: stageMs
            ))

        case .prefixCacheLookupV2(let message):
            return .prefixCacheLookupV2(message)

        case .prefixCacheReadyV2(let message):
            return .prefixCacheReadyV2(message)
        }
    }

    public static func encodeOutboundMessage(_ outbound: OutboundMessage) throws -> Data {
        try ProviderProtocolCodec.encodeProviderMessage(providerMessage(for: outbound))
    }

    public static func encodeOutboundMessageString(_ outbound: OutboundMessage) throws -> String {
        try ProviderProtocolCodec.encodeProviderMessageString(providerMessage(for: outbound))
    }

    public static func decodeIncomingMessage(from data: Data) throws -> CoordinatorMessage {
        try ProviderProtocolCodec.decodeCoordinatorMessage(from: data)
    }

    public static func decodeIncomingMessage(from string: String) throws -> CoordinatorMessage {
        try ProviderProtocolCodec.decodeCoordinatorMessage(from: string)
    }
}
