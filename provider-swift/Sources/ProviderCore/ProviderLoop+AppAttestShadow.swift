import Foundation
import Darwin
import ProviderAppAttest

extension ProviderLoop {
    func handleAppAttestShadow(_ request: AppAttestShadowPayload, reply: AppAttestShadowReply) {
        guard ["prepare", "attest", "assert"].contains(request.action),
              request.session.utf8.count <= 64, (request.keyID?.utf8.count ?? 0) <= 64,
              (request.challenge?.utf8.count ?? 0) <= 64 else { return }
        guard appAttestShadowTask == nil else { return }
        if usesAppAttestWorker {
            handleAppAttestWorker(request, reply: reply)
            return
        }
        var request = request
        if request.action == "assert" {
            // Decrypt with OUR process key; never accept a public key supplied by
            // another process to ask App Attest to certify its endpoint.
            guard let encrypted = request.encryptedChallenge,
                  encrypted.ciphertext.utf8.count <= 256,
                  let clear = try? keyPair.decryptPayload(EncryptedPayload(
                    ephemeralPublicKey: encrypted.ephemeralPublicKey, ciphertext: encrypted.ciphertext)),
                  let challenge = String(data: clear, encoding: .utf8) else {
                var response = AppAttestShadowPayload(action: "assertion", session: request.session)
                response.protocolVersion = request.protocolVersion
                response.result = "decryption_failed"
                Task { await reply.send(response) }
                return
            }
            request.challenge = challenge
            request.encryptedChallenge = nil
        }
        if appAttestShadowClient == nil {
            let probe = AppAttestProcessProbe(pushHistory: apnsPushHistory)
            appAttestShadowClient = AppAttestShadowClient(
                scope: loopConfig.coordinatorURL, processDiagnostics: { probe.diagnostics() })
        }
        guard let client = appAttestShadowClient else { return }
        let publicKey = keyPair.publicKeyBase64
        let generation = appAttestShadowGeneration
        let message = request
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let status = AppAttestStatus(osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", osBuild: appAttestOSBuild(), appVersion: ProviderCore.version, chip: loopConfig.hardware.chipName, binaryHash: binaryHash ?? "",
            machineModel: loopConfig.hardware.machineModel, memoryGB: String(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)),
            cpuTotal: String(loopConfig.hardware.cpuCores.total), cpuPerformance: String(loopConfig.hardware.cpuCores.performance),
            cpuEfficiency: String(loopConfig.hardware.cpuCores.efficiency), gpuCores: String(loopConfig.hardware.gpuCores), attestationPublicKey: signer?.publicKeyBase64)
        appAttestShadowTask = Task.detached(priority: .utility) { [weak self] in
            let response = await client.respond(to: message, publicKey: publicKey, status: status)
            let localStatus = await client.currentLocalStatus()
            guard !Task.isCancelled else { return }
            await self?.finishAppAttestShadow(response, localStatus: localStatus, prepared: message.action == "prepare",
                                              generation: generation, reply: reply)
        }
    }

    func finishAppAttestShadow(_ response: AppAttestShadowPayload, localStatus: AppAttestLocalStatus?,
                                        prepared: Bool, generation: UInt64, reply: AppAttestShadowReply) async {
        guard generation == appAttestShadowGeneration else { return }
        // Proof key/history updates and failures reach doctor and report now,
        // not at the next prepare; the daemon keeps its current stall fields.
        if let localStatus, let published = AppAttestLocalStatus.published(
            current: appAttestLocalStatus, client: localStatus, prepared: prepared) {
            appAttestLocalStatus = published
            writeDaemonState()
        }
        // Only these results can leave an unanswered Apple call holding admission.
        if !usesAppAttestWorker && (response.result == "busy" || response.result == "operation_timeout") { startAppAttestStallMonitorIfNeeded() }
        appAttestShadowTask = nil
        await reply.send(response)
    }

    func cancelAppAttestShadow(stopWorker: Bool = false) {
        appAttestShadowGeneration &+= 1
        appAttestShadowTask?.cancel()
        appAttestShadowTask = nil
        if stopWorker { appAttestWorkerStopReason = .shutdown }
        if let worker = appAttestWorkerClient {
            let previous = appAttestWorkerRetirement
            let permanently = appAttestWorkerStopped
            appAttestWorkerRetirement = Task {
                _ = await previous?.value
                do {
                    if permanently { try await worker.stop() }
                    else { try await worker.cancelExchange() }
                    return true
                } catch {
                    // A worker that cannot be reaped quarantines its own slot.
                    // Never recover verification by restarting the inference process.
                    logger.warning("App Attest worker retirement failed; verification remains paused")
                    return false
                }
            }
        }
    }

    /// A shutdown/re-exec boundary, not a fire-and-forget cleanup task. A
    /// stopped child can hold the credential lease until it is actually reaped.
    func stopAppAttestWorkerAndWait() async -> Bool {
        cancelAppAttestShadow(stopWorker: true)
        return await appAttestWorkerRetirement?.value ?? true
    }

    func stopAppAttestWorkerForUpdateAndWait() async -> Bool {
        guard !Task.isCancelled, !isShuttingDown, updatePhase == .draining,
              servingDrain.owner == .update, appAttestWorkerStopReason != .shutdown else { return false }
        appAttestWorkerStopReason = .update
        cancelAppAttestShadow()
        let retired = await appAttestWorkerRetirement?.value ?? true
        return retired && appAttestWorkerStopReason == .update
    }

    @discardableResult
    func resumeAppAttestWorkerAfterUpdate() async -> Bool {
        guard appAttestWorkerStopReason == .update, updatePhase == .idle,
              !isShuttingDown, !servingDrain.refusingForServiceChange else { return false }
        let generation = appAttestShadowGeneration
        let retired = await appAttestWorkerRetirement?.value ?? true
        guard retired, generation == appAttestShadowGeneration,
              appAttestWorkerStopReason == .update, updatePhase == .idle,
              !isShuttingDown, !servingDrain.refusingForServiceChange else { return false }
        appAttestWorkerClient = nil
        appAttestWorkerRetirement = nil
        appAttestWorkerStopReason = nil
        return true
    }
}

func appAttestOSBuild() -> String {
    var size=0
    guard sysctlbyname("kern.osversion",nil,&size,nil,0)==0, size>0, size<128 else { return "" }
    var bytes=[CChar](repeating:0,count:size)
    guard sysctlbyname("kern.osversion",&bytes,&size,nil,0)==0 else { return "" }
    return String(cString:bytes)
}
