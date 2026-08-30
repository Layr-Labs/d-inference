import Foundation

struct PrivateV2ExecutionContext: Sendable {
    let endpoint: PrivateV2Endpoint
    let body: Data
    let expectedModelManifestHash: String
    let requestedMaxOutputTokens: UInt64
    let releaseGeneration: UInt64
    let modelGeneration: UInt64
    let requiresVision: Bool
    let streamAdapter: PrivateV2NativeStreamAdapter
    let writer: PrivateV2ChunkWriter
}

extension ProviderLoop {
    internal func handlePrivateV2Request(
        _ request: PrivateV2Request,
        send transport: SendHandle
    ) async {
        guard request.version == PrivateV2Protocol.version,
              let keyPair,
              let binaryHash,
              !binaryHash.isEmpty
        else { return }

        let deadline: Date
        let transcriptDigest: Data
        let clientPublicKey: Data
        let kdfSalt: Data
        let nonce: Data
        let ciphertext: Data
        do {
            deadline = try PrivateV2Date.parse(request.deadline)
            let now = Date()
            guard deadline > now else { throw PrivateV2Error.deadlineExpired }
            guard deadline.timeIntervalSince(now) <= PrivateV2Protocol.maximumLeaseLifetime else {
                throw PrivateV2Error.leaseTooLong
            }
            transcriptDigest = try Base64URL.decode(request.transcriptDigest)
            guard transcriptDigest.count == 32 else { throw PrivateV2Error.invalidLength }
            let expectedDigest = PrivateV2Transcript(request: request).digest()
            guard PrivateV2Crypto.constantTimeEqual(transcriptDigest, expectedDigest) else {
                throw PrivateV2Error.transcriptMismatch
            }
            try privateV2ReplayLedger.claim(
                leaseId: request.leaseId,
                requestId: request.requestId,
                expiresAt: deadline,
                now: now)
            clientPublicKey = try Base64URL.decode(request.clientPublicKey)
            kdfSalt = try Base64URL.decode(request.kdfSalt)
            nonce = try Base64URL.decode(request.nonce)
            ciphertext = try Base64URL.decode(request.ciphertext)
            guard clientPublicKey.count == 32, kdfSalt.count == 32, nonce.count == 12
            else { throw PrivateV2Error.invalidLength }
            guard ["public", "self_route_only", "prefer_owner"].contains(request.routeMode),
                  request.requestedMaxOutputTokens > 0,
                  request.requestedMaxOutputTokens <= PrivateV2Protocol.maximumOutputTokens
            else { throw PrivateV2Error.requestMismatch }
            if request.routeMode == "public" {
                guard request.ownerBinding.isEmpty else {
                    throw PrivateV2Error.requestMismatch
                }
            } else {
                guard (try Base64URL.decode(request.ownerBinding)).count == 32 else {
                    throw PrivateV2Error.requestMismatch
                }
            }
        } catch {
            logger.warning("[\(request.requestId)] rejecting malformed private-v2 envelope")
            return
        }

        let keyMaterial: PrivateV2KeyMaterial
        do {
            keyMaterial = try keyPair.privateV2KeyMaterial(
                clientPublicKey: clientPublicKey,
                salt: kdfSalt,
                transcriptDigest: transcriptDigest)
        } catch {
            logger.warning("[\(request.requestId)] rejecting private-v2 key agreement")
            return
        }

        let writer = PrivateV2ChunkWriter(
            requestId: request.requestId,
            transcriptDigest: transcriptDigest,
            responseKey: keyMaterial.responseKey
        ) { chunk in
            if chunk.terminal {
                transport.send(.privateChunkV2(chunk))
            } else {
                transport.sendChunk(.privateChunkV2(chunk))
            }
        }

        let rejectEncrypted: (PrivateV2Error, String, Int) -> Void = { _, code, status in
            let payload = PrivateV2EndpointAdapter.errorPayload(
                endpoint: request.endpoint,
                failureCode: code)
            _ = try? writer.emit(
                payload: payload,
                terminal: true,
                failureCode: code,
                statusCode: status)
        }

        let plaintext: Data
        do {
            plaintext = try PrivateV2Crypto.open(
                ciphertext,
                key: keyMaterial.requestKey,
                nonce: nonce,
                aad: try PrivateV2Crypto.requestAAD(transcriptDigest: transcriptDigest))
        } catch {
            logger.warning("[\(request.requestId)] rejecting private-v2 authentication failure")
            rejectEncrypted(.decryptionFailed, "invalid_request", 400)
            return
        }

        let inner: PrivateV2InnerRequest
        do {
            inner = try PrivateV2InnerRequest.decode(plaintext)
            let localReleaseGeneration =
                updateLifecycle.record.command?.desiredGeneration
                ?? updateLifecycle.record.warmIntents.compactMap(\.desiredGeneration).max()
                ?? 0
            guard let currentModelHash =
                    liveModelHashes[request.model] ?? modelHashes[request.model]
            else { throw PrivateV2Error.modelMismatch }
            try PrivateV2IdentityValidator.validate(
                inner: inner,
                outer: request,
                currentReleaseBinaryHash: binaryHash,
                currentReleaseGeneration: localReleaseGeneration,
                currentModelManifestHash: currentModelHash,
                currentModelGeneration: desiredModelGeneration)
        } catch let error as PrivateV2Error {
            logger.warning("[\(request.requestId)] rejecting private-v2 identity mismatch")
            rejectEncrypted(error, "invalid_request", 400)
            return
        } catch {
            logger.warning("[\(request.requestId)] rejecting private-v2 inner envelope")
            rejectEncrypted(.invalidInnerRequest, "invalid_request", 400)
            return
        }

        let chatBody: Data
        do {
            // This is deliberately the first endpoint/body parse. Every
            // transcript and executing-artifact check above completed first.
            chatBody = try PrivateV2EndpointAdapter.chatRequestBody(
                endpoint: request.endpoint,
                model: request.model,
                stream: request.stream,
                requestedMaxOutputTokens: request.requestedMaxOutputTokens,
                defaultMaxOutputTokens: UInt64(Self.schedulerDefaultMaxTokens),
                requiresVision: request.requiresVision,
                body: inner.body)
        } catch {
            rejectEncrypted(.invalidBody, "invalid_request", 400)
            return
        }

        let streamAdapter = PrivateV2NativeStreamAdapter(
            endpoint: request.endpoint,
            requestId: request.requestId,
            model: request.model)
        let privateSend = SendHandle { outbound in
            switch outbound {
            case .inferenceAccepted:
                break
            case .inferenceComplete(_, let usage, let stopSequence, _, _):
                guard usage.completionTokens <= request.requestedMaxOutputTokens else {
                    let code = InferenceFailureCode.internalFailure.rawValue
                    _ = try? writer.emit(
                        payload: PrivateV2EndpointAdapter.errorPayload(
                            endpoint: request.endpoint, failureCode: code),
                        terminal: true,
                        failureCode: code,
                        statusCode: 500)
                    break
                }
                let privateUsage = PrivateV2Usage(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens)
                for payload in streamAdapter.closingPayloads(
                    usage: privateUsage,
                    stopSequence: stopSequence) {
                    _ = try? writer.emit(payload: payload, terminal: false)
                }
                _ = try? writer.emit(
                    payload: streamAdapter.terminalPayload(usage: privateUsage),
                    terminal: true,
                    usage: privateUsage)
            case .inferenceError(_, let failure):
                let code = failure.code.rawValue
                let payload = PrivateV2EndpointAdapter.errorPayload(
                    endpoint: request.endpoint,
                    failureCode: code)
                _ = try? writer.emit(
                    payload: payload,
                    terminal: true,
                    failureCode: code,
                    statusCode: Int(failure.statusCode))
            default:
                // No private-v2 path ever emits a legacy inference wire type.
                break
            }
        }

        await handleInferenceRequest(
            requestId: request.requestId,
            ciphertext: Data(),
            senderPublicKey: nil,
            cacheReceiptNonce: nil,
            authenticatedCacheScope: nil,
            prefixCacheProtocol: nil,
            toolSchemaMetadataProtocol: nil,
            firstContentDeadline: nil,
            privateV2: PrivateV2ExecutionContext(
                endpoint: request.endpoint,
                body: chatBody,
                expectedModelManifestHash: request.modelManifestHash,
                requestedMaxOutputTokens: request.requestedMaxOutputTokens,
                releaseGeneration: request.releaseGeneration,
                modelGeneration: request.modelGeneration,
                requiresVision: request.requiresVision,
                streamAdapter: streamAdapter,
                writer: writer),
            send: privateSend)
    }
}
