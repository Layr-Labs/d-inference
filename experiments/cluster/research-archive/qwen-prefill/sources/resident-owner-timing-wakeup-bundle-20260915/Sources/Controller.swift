import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

@main struct Controller {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { Darwin.exit(64) }
        var endpoints: [ClusterRemoteWorkerEndpoint] = []
        var pair: ClusterWorkerPair?
        let cohort = TimingCohort()
        var config: TimingSettings?
        var success = false, failure: String?, configSHA = ""
        var timer: DispatchSourceTimer?
        let began = DispatchTime.now().uptimeNanoseconds
        var stamps: [String: UInt64] = ["controllerBegan": began]
        var ownerDrainLimit = began + 302_000_000_000
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(305) // Includes final publication; never constitutes remote cleanup proof.
        do {
            let (raw, sha) = try readQualificationJSON(CommandLine.arguments[1], maximum: 500_000); configSHA = sha
            let value = try TimingSettings.parse(raw); config = value
            let template = try qualificationTemplate(value.readyTemplateBase64)
            let identity = ClusterWorkerIdentity(membershipEpoch: UUID(uuidString: value.membershipEpoch)!, modelID: template.identity.modelID,
                artifactSHA256: template.identity.artifactSHA256, configurationSHA256: template.identity.configurationSHA256,
                peers: template.identity.peers)
            let deadline = began + UInt64(value.lifetimeSeconds) * 1_000_000_000
            ownerDrainLimit = deadline + 2_000_000_000; alarm(UInt32(value.lifetimeSeconds + 5))
            let bootstrap = try ClusterOwnerBootstrapRelay(identity: identity, executionPlanSHA256: template.executionPlanSHA256,
                deadlineUptimeNanoseconds: min(deadline, began + UInt64(min(value.startupSeconds, 30)) * 1_000_000_000))
            try qualificationEmit(["schema": "owner_timing_cohort_started_v1", "configurationSHA256": configSHA,
                "cpuQualification": value.cpuQualification, "membershipEpoch": value.membershipEpoch,
                "cohortLabel": value.cohortLabel, "policyLabel": value.policyLabel, "policyLabelIsCallerSupplied": true,
                "warmupCount": value.warmupCount, "measuredCount": value.measuredCount,
                "promptTokenIDsSHA256": timingTokenHash(value.promptTokenIDs), "expectedTokenIDsSHA256": timingTokenHash(value.expectedTokenIDs),
                "performanceQualification": false, "fullNumericalComparisonPerformed": false, "externalTTFTMeasured": false])
            for rank in 0..<2 {
                let peer = value.peers[rank]
                let ssh = try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                    knownHostsFile: URL(fileURLWithPath: peer.knownHostsFile), identityFile: URL(fileURLWithPath: peer.identityFile),
                    installedDarkbloom: peer.installedOwner)
                endpoints.append(try ClusterRemoteWorkerEndpoint(configuration: ssh, clusterID: value.clusterID, expectedIdentity: identity,
                    profile: template.profile, rank: rank, executionPlanSHA256: template.executionPlanSHA256,
                    lifetimeDeadlineUptimeNanoseconds: deadline, bootstrapRelay: bootstrap))
            }
            stamps["endpointsCreated"] = DispatchTime.now().uptimeNanoseconds
            let owned = endpoints
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .init(uptimeNanoseconds: deadline))
            watchdog.setEventHandler { for endpoint in owned { endpoint.requestNativeCleanup() } }
            watchdog.resume(); timer = watchdog
            let opened = try ClusterWorkerPair(workers: endpoints, startupDeadline: min(deadline, began + UInt64(value.startupSeconds) * 1_000_000_000))
            pair = opened; stamps["pairReady"] = DispatchTime.now().uptimeNanoseconds
            try await cohort.run(pair: opened, configuration: value, lifetimeDeadline: deadline) { record in
                try qualificationEmit(["schema": "owner_timing_request_v1", "configurationSHA256": configSHA,
                    "observation": try record.object, "externalTTFTMeasured": false, "performanceQualification": false])
            }
            success = true
        } catch { failure = String(String(describing: error).prefix(2048)) }
        stamps["cleanupBegan"] = DispatchTime.now().uptimeNanoseconds
        if !success {
            cohort.active?.cancel(reason: .runtimeError)
            for endpoint in endpoints { endpoint.requestNativeCleanup() }
        }
        // Actual retirement/terminal evidence, not SSH EOF or a sent signal.
        if let pair { await pair.shutdown() }
        else { for endpoint in endpoints { await endpoint.waitUntilNativeCleanup() } }
        stamps["nativeCleanupWaitReturned"] = DispatchTime.now().uptimeNanoseconds
        if endpoints.count != 2 || !endpoints.allSatisfy(\.nativeCleanupObserved) {
            success = false; failure = failure ?? "Missing actual native cleanup"
        }
        let drainDeadline = min(ownerDrainLimit, DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        while !endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved), DispatchTime.now().uptimeNanoseconds < drainDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved) {
            success = false; failure = failure ?? "Missing authenticated device lease release acknowledgment"
        }
        stamps["leaseDrainEnded"] = DispatchTime.now().uptimeNanoseconds
        timer?.cancel()
        var result: [String: Any] = ["schema": "owner_timing_cohort_result_v1", "configurationSHA256": configSHA,
            "completed": success, "clock": "DispatchTime.uptimeNanoseconds.same_controller_process",
            "measurement": "internal owner-control start-to-first committed-token callback; excludes load and reserve; includes transport/control",
            "timestamps": stamps, "elapsedControllerNanoseconds": DispatchTime.now().uptimeNanoseconds - began,
            "nativeCleanupObserved": endpoints.map(\.nativeCleanupObserved),
            "ownerDeviceLeaseReleasedObserved": endpoints.map(\.ownerDeviceLeaseReleasedObserved),
            "endpointDiagnosticsBase64": endpoints.map { $0.diagnosticTail.base64EncodedString() },
            "journalRelease": "Authenticated owner acknowledgment; separate remote journal/process observation remains useful",
            "performanceQualification": false, "fullNumericalComparisonPerformed": false, "externalTTFTMeasured": false,
            "policyEngagementIndependentlyVerified": false, "providerCapacityUpdated": false]
        if let config {
            result["cpuQualification"] = config.cpuQualification
            result["cohortLabel"] = config.cohortLabel; result["policyLabel"] = config.policyLabel
            result["policyLabelIsCallerSupplied"] = true
            result["promptTokenIDsSHA256"] = timingTokenHash(config.promptTokenIDs)
            result["expectedTokenIDsSHA256"] = timingTokenHash(config.expectedTokenIDs)
            var summary = timingSummary(cohort.records, warmups: config.warmupCount, measured: config.measuredCount)
            if !success {
                summary["complete"] = false
                summary.removeValue(forKey: "measuredInternalOwnerControlFirstTokenNanoseconds")
                summary.removeValue(forKey: "medianInternalOwnerControlFirstTokenNanoseconds")
            }
            result["summary"] = summary
        }
        do { result["requests"] = try cohort.records.map { try $0.object } } catch { success = false; failure = failure ?? "Cannot encode request observations" }
        result["completed"] = success
        if let failure { result["failure"] = failure }
        do { try qualificationEmit(result) } catch { Darwin.exit(74) }
        alarm(0)
        if !success { Darwin.exit(1) }
    }
}
