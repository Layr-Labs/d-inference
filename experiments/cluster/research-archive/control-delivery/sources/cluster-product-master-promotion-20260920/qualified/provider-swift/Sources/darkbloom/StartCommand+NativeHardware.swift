#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation
import ProviderCore

extension Start {
    func runNativeHardwareLeader(path:String,pin:String) async throws {
        let (input,exactPin)=try NativeHardwareInput.load(path:path,pin:pin)
        let configPath=try configOptions.config.map { URL(fileURLWithPath:($0 as NSString).expandingTildeInPath) } ?? ConfigManager.defaultConfigPath()
        let factory=try DistributedStartSessionFactory(providerConfiguration:configPath)
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer{ProcessLifecycle.releaseSingleInstanceLock()}
        // SAME real saved attachment, signer, installed owner and ProviderLoop.
        let loop=try await makeClusterMemberLoop(reference:factory.reference,stopOnDisconnect:true)
        let signals=try DistributedStartSignals();defer{signals.close()}
        let serving=Task {try await loop.run()}
        let request=Task {
            try await loop.waitForClusterMemberRegistration(until:.now.advanced(by:.seconds(30)))
            try await executeNativeHardwareRequest(loop:loop,input:input,pin:exactPin)
        }
        signals.attach{request.cancel()} // cancellation retains loop during actual cleanup
        do {
            try await withTaskCancellationHandler {try await request.value} onCancel:{request.cancel()}
            serving.cancel();_ = try? await serving.value
        } catch {
            // request only returns after its owned cleanup; if that never
            // completes the root's absolute process fence remains required.
            serving.cancel();_ = try? await serving.value
            throw error
        }
    }
}
#endif
