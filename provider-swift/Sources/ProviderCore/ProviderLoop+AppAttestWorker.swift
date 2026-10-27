import Foundation
import ProviderAppAttest

extension ProviderLoop {
    func handleAppAttestWorker(_ request: AppAttestShadowPayload, reply: AppAttestShadowReply) {
        guard !isShuttingDown, servingDrain.owner != .lifecycle else { return }
        if appAttestWorkerStopped {
            guard appAttestWorkerStopReason == .update else { return }
            // An add-on hold keeps the worker serving; only a service change waits.
            guard request.action == "prepare", updatePhase == .idle, !servingDrain.refusingForServiceChange else {
                Task { await reply.send(Self.workerUnavailableReply(to: request)) }
                return
            }
            // Retry bounded stop/reap on the retained owner, never discard an
            // uncertain child. Only a fresh prepare can recover update quarantine.
            cancelAppAttestShadow()
            let generation = appAttestShadowGeneration
            appAttestShadowTask = Task { [weak self] in
                await self?.retryUpdateRetiredWorker(request, reply: reply, generation: generation)
            }
            return
        }
        if appAttestWorkerClient == nil {
            guard request.action == "prepare" else {
                Task { await reply.send(Self.workerUnavailableReply(to: request)) }
                return
            }
            do {
                appAttestWorkerClient = try AppAttestWorkerClient(
                    scope: loopConfig.coordinatorURL,
                    endpointPublicKey: keyPair.publicKeyBase64,
                    custody: { [keyPair] request in
                        let encrypted = request.encryptedChallenge
                        let clear = try keyPair.decryptPayload(EncryptedPayload(
                            ephemeralPublicKey: encrypted.ephemeralPublicKey,
                            ciphertext: encrypted.ciphertext))
                        guard let value = String(data: clear, encoding: .utf8) else {
                            throw AppAttestWorkerError.invalidMessage
                        }
                        return value
                    })
            } catch {
                Task { await reply.send(Self.workerUnavailableReply(to: request)) }
                return
            }
        }
        guard let client = appAttestWorkerClient else { return }
        let generation = appAttestShadowGeneration
        let retirement = appAttestWorkerRetirement
        let qualification = nativeWorkerQualification
        let probe = AppAttestProcessProbe(pushHistory: apnsPushHistory)
        let runtime = AppAttestRuntimeContext.current()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let status = AppAttestStatus(
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            osBuild: appAttestOSBuild(), appVersion: ProviderCore.version,
            chip: loopConfig.hardware.chipName, binaryHash: binaryHash ?? "",
            machineModel: loopConfig.hardware.machineModel,
            memoryGB: String(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)),
            cpuTotal: String(loopConfig.hardware.cpuCores.total),
            cpuPerformance: String(loopConfig.hardware.cpuCores.performance),
            cpuEfficiency: String(loopConfig.hardware.cpuCores.efficiency),
            gpuCores: String(loopConfig.hardware.gpuCores), attestationPublicKey: signer?.publicKeyBase64)
        appAttestShadowTask = Task.detached(priority: .utility) { [weak self] in
            // Disconnect retirement must finish before the next transport can
            // start verification. An old cancellation cannot kill a successor.
            _ = await retirement?.value
            guard !Task.isCancelled else { return }
            var response: AppAttestShadowPayload
            var local: AppAttestLocalStatus?
            do {
                let result = try await client.respond(to: request, status: status)
                qualification?.recordReply(action: result.payload.action, result: result.payload.result,
                    workerPID: result.runtimeDiagnostics?.processID)
                response = result.payload
                local = result.localStatus
            } catch {
                response = Self.workerUnavailableReply(to: request)
            }
            guard !Task.isCancelled else { return }
            let diagnostics = await probe.diagnostics()
            if response.action == "ready" {
                response.launchSession = runtime.launchSession
                response.bootTime = runtime.bootTime
                response.attach(diagnostics)
            }
            local?.launchSession = runtime.launchSession
            local?.bootTime = runtime.bootTime
            local?.process = diagnostics
            guard !Task.isCancelled else { return }
            await self?.finishAppAttestShadow(response, localStatus: local,
                prepared: request.action == "prepare", generation: generation, reply: reply)
        }
    }

    private func retryUpdateRetiredWorker(_ request: AppAttestShadowPayload,
        reply: AppAttestShadowReply, generation: UInt64) async {
        let resumed = await resumeAppAttestWorkerAfterUpdate()
        guard generation == appAttestShadowGeneration else { return }
        appAttestShadowTask = nil
        guard !Task.isCancelled else { return }
        if resumed {
            handleAppAttestWorker(request, reply: reply)
        } else {
            await reply.send(Self.workerUnavailableReply(to: request))
        }
    }

    private nonisolated static func workerUnavailableReply(to request: AppAttestShadowPayload) -> AppAttestShadowPayload {
        let action = request.action == "prepare" ? "ready" : request.action == "attest" ? "attestation" : "assertion"
        var reply = AppAttestShadowPayload(action: action, session: request.session)
        reply.protocolVersion = 3
        // Infrastructure errors must not masquerade as Apple's invalid-key
        // result and spend credential-rotation budgets.
        reply.result = "busy"
        return reply
    }
}
