import Foundation
import Darwin
import ProviderAppAttest

extension ProviderLoop {
    func handleAppAttestShadow(_ request: AppAttestShadowPayload, send: SendHandle) {
        guard ["prepare", "attest", "assert"].contains(request.action),
              request.session.utf8.count <= 64, (request.keyID?.utf8.count ?? 0) <= 64,
              (request.challenge?.utf8.count ?? 0) <= 64 else { return }
        guard appAttestShadowTask == nil else { return }
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
                response.result = "decryption_failed"
                send.send(.appAttestShadow(response)); return
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
            let reply = await client.respond(to: message, publicKey: publicKey, status: status)
            let localStatus = await client.currentLocalStatus()
            guard !Task.isCancelled else { return }
            await self?.finishAppAttestShadow(reply, localStatus: localStatus, prepared: message.action == "prepare",
                                              generation: generation, send: send)
        }
    }

    private func finishAppAttestShadow(_ reply: AppAttestShadowPayload, localStatus: AppAttestLocalStatus?,
                                       prepared: Bool, generation: UInt64, send: SendHandle) {
        // Proof key/history updates and failures reach doctor and report now,
        // not at the next prepare; the daemon keeps its current stall fields.
        if let localStatus, let published = AppAttestLocalStatus.published(
            current: appAttestLocalStatus, client: localStatus, prepared: prepared) {
            appAttestLocalStatus = published
            writeDaemonState()
        }
        // Only these results can leave an unanswered Apple call holding admission.
        if reply.result == "busy" || reply.result == "operation_timeout" { startAppAttestStallMonitorIfNeeded() }
        guard generation == appAttestShadowGeneration else { return }
        appAttestShadowTask = nil
        send.send(.appAttestShadow(reply))
    }

    func cancelAppAttestShadow() {
        appAttestShadowGeneration &+= 1
        appAttestShadowTask?.cancel()
        appAttestShadowTask = nil
    }
}

private func appAttestOSBuild() -> String {
    var size=0
    guard sysctlbyname("kern.osversion",nil,&size,nil,0)==0, size>0, size<128 else { return "" }
    var bytes=[CChar](repeating:0,count:size)
    guard sysctlbyname("kern.osversion",&bytes,&size,nil,0)==0 else { return "" }
    return String(cString:bytes)
}
