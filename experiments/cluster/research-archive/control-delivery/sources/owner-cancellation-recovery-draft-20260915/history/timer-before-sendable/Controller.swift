import Foundation
import Darwin

/// Private qualification command. No benchmark timings or product capacity are
/// inferred; one selected cancellation and one new-epoch restart per invocation.
@MainActor @main struct Controller {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { Darwin.exit(64) }
        let began = DispatchTime.now().uptimeNanoseconds
        let hardExit = DispatchSource.makeTimerSource(queue: .global())
        hardExit.schedule(deadline: .init(uptimeNanoseconds: began + 305_000_000_000))
        hardExit.setEventHandler { Darwin._exit(124) }; hardExit.resume()
        // Self-exit bounds the controller only; it is never remote cleanup proof.
        // Owner lifetimes/sticky journals remain authoritative on loss of control.
        let factory = CancellationRemoteFactory(), cohort = CancellationCohort()
        var settings: CancellationSettings?, hash = "", failure: String?
        var deadline = began + 300_000_000_000
        do {
            let (raw, pin) = try readQualificationJSON(CommandLine.arguments[1], maximum: 500_000)
            hash = pin; let config = try CancellationSettings.parse(raw); settings = config
            deadline = began + UInt64(config.lifetimeSeconds) * 1_000_000_000
            hardExit.schedule(deadline: .init(uptimeNanoseconds: deadline + 5_000_000_000))
            try qualificationEmit(["schema": "owner_cancellation_recovery_started_v1", "configurationSHA256": hash,
                "cancellationCase": config.cancellationCase.rawValue, "cancellationEpoch": config.cancellationEpoch,
                "recoveryEpoch": config.recoveryEpoch, "promptTokenIDsSHA256": cancellationTokenHash(config.promptTokenIDs),
                "expectedTokenIDsSHA256": cancellationTokenHash(config.expectedTokenIDs), "nativeKernelPhaseObserved": false])
            try await cohort.run(configuration: config, lifetimeDeadline: deadline, makePair: { epoch in
                try await factory.open(epoch: epoch, configuration: config, lifetimeDeadline: deadline)
            }, publish: { record in
                try qualificationEmit(["schema": "owner_cancellation_request_v1", "configurationSHA256": hash,
                    "observation": try record.object])
            })
        } catch { failure = String(String(describing: error).prefix(2048)) }
        await factory.drain(lifetimeDeadline: deadline)
        let native = factory.endpoints.map(\.nativeCleanupObserved)
        let leases = factory.endpoints.map(\.ownerDeviceLeaseReleasedObserved)
        if native != [true, true, true, true] || leases != [true, true, true, true] {
            failure = failure ?? "Expected both generations of native cleanup and owner lease acknowledgments"
        }
        var result: [String: Any] = ["schema": "owner_cancellation_recovery_result_v1", "configurationSHA256": hash,
            "completed": failure == nil && cohort.records.count == 2 && cohort.records.allSatisfy(\.completed),
            "nativeCleanupObserved": native, "ownerDeviceLeaseReleasedObserved": leases,
            "clock": "DispatchTime.uptimeNanoseconds.same_controller_process",
            "elapsedControllerNanoseconds": DispatchTime.now().uptimeNanoseconds - began,
            "freshPairAndMembershipRequired": true, "oldEpochReuseQualified": false,
            "independentRemoteJournalObservation": false, "journalStatus": "owner lease ACK observed; root postflight must inspect journals/processes",
            "nativeKernelPhaseObserved": false, "fullNumericalComparisonPerformed": false,
            "externalTTFTMeasured": false, "performanceQualification": false, "providerCapacityUpdated": false]
        if let settings { result["cancellationCase"] = settings.cancellationCase.rawValue }
        if let failure { result["failure"] = failure }
        do { result["requests"] = try cohort.records.map { try $0.object }; try qualificationEmit(result) }
        catch { Darwin.exit(74) }
        hardExit.cancel()
        if failure != nil { Darwin.exit(1) }
    }
}
