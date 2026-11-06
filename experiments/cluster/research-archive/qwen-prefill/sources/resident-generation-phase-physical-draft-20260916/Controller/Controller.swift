import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

struct PeerSettings: Decodable {
    let host: String, user: String, knownHostsFile: String, identityFile: String, installedOwner: String
    let port: Int
}
struct ControllerSettings: Decodable {
    let schema: String
    let cpuQualification: Bool
    let clusterID: String
    let readyTemplateBase64: String
    let peers: [PeerSettings]
    let membershipEpoch: String
    let requestID: String
    let promptTokenIDs: [Int]
    let stopTokenIDs: [Int]
    let outputCount: Int
    let chunkSize: Int
    let expectedTokenIDs: [Int]?
    let lifetimeSeconds: Int
    let startupSeconds: Int
    let requestSeconds: Int
}
final class CapturedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private var finish: String?
    private var failure: String?
    func accept(_ event: ClusterWorkerRequestEvent) -> Bool {
        lock.withLock {
            switch event {
            case .token(let id): ids.append(id)
            case .finished(let reason): finish = reason.rawValue
            case .failed(let message): failure = message
            }
        }
        return true
    }
    var snapshot: ([Int], String?, String?) { lock.withLock { (ids, finish, failure) } }
}
@main struct Controller {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { Darwin.exit(64) }
        var endpoints: [ClusterRemoteWorkerEndpoint] = []
        var pair: ClusterWorkerPair?
        var request: ClusterWorkerRequest?
        var success = false
        var failure: String?
        var configSHA = "", cpu = true
        let captured = CapturedTokens()
        var timer: DispatchSourceTimer?
        // PHASE OBSERVATION BEGIN
        var actualReadyCapacityBytes: [Int] = []
        var admittedReservedBytes: Int?
        var bytesBeforeRelease: Int?
        var bytesAfterRelease: Int?
        var actualRequestRetired = false
        // PHASE OBSERVATION END
        let began = DispatchTime.now().uptimeNanoseconds
        var ownerDrainLimit = began + 302_000_000_000
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(305) // Also bounds publication after a configuration refusal.
        do {
            let (raw, sha) = try readQualificationJSON(CommandLine.arguments[1], maximum: 500_000); configSHA = sha
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any], Set(object.keys) ==
                Set(["schema", "cpuQualification", "clusterID", "readyTemplateBase64", "peers", "membershipEpoch", "requestID",
                     "promptTokenIDs", "stopTokenIDs", "outputCount", "chunkSize", "expectedTokenIDs", "lifetimeSeconds", "startupSeconds", "requestSeconds"]),
                  let peers = object["peers"] as? [[String: Any]], peers.allSatisfy({ Set($0.keys) ==
                    Set(["host", "user", "knownHostsFile", "identityFile", "installedOwner", "port"]) }) else { throw QualificationFailure.invalid("Controller fields differ") }
            let config = try JSONDecoder().decode(ControllerSettings.self, from: raw); cpu = config.cpuQualification
            guard config.schema == "darkbloom_owner_qualification_v1", config.peers.count == 2,
                  (1...300).contains(config.lifetimeSeconds), (1...config.lifetimeSeconds).contains(config.startupSeconds),
                  (1...config.lifetimeSeconds).contains(config.requestSeconds),
                  let epoch = UUID(uuidString: config.membershipEpoch), epoch.uuidString.lowercased() == config.membershipEpoch,
                  let id = UUID(uuidString: config.requestID), id.uuidString.lowercased() == config.requestID,
                  !config.cpuQualification || (config.outputCount == 2 && config.expectedTokenIDs == [9, 10] && config.stopTokenIDs.isEmpty) else {
                throw QualificationFailure.invalid("Controller geometry/identity outside bounds")
            }
            let template = try qualificationTemplate(config.readyTemplateBase64)
            let identity = ClusterWorkerIdentity(membershipEpoch: epoch, modelID: template.identity.modelID,
                artifactSHA256: template.identity.artifactSHA256, configurationSHA256: template.identity.configurationSHA256, peers: template.identity.peers)
            let deadline = began + UInt64(config.lifetimeSeconds) * 1_000_000_000
            ownerDrainLimit = deadline + 2_000_000_000
            alarm(UInt32(config.lifetimeSeconds + 5)) // Last-resort controller bound, never remote cleanup proof.
            let bootstrap = try ClusterOwnerBootstrapRelay(identity: identity, executionPlanSHA256: template.executionPlanSHA256,
                deadlineUptimeNanoseconds: min(deadline, began + UInt64(min(config.startupSeconds, 30)) * 1_000_000_000))
            try qualificationEmit(["schema": "owner_qualification_started_v1", "configurationSHA256": configSHA,
                "cpuQualification": cpu, "membershipEpoch": config.membershipEpoch, "requestID": config.requestID,
                "promptCount": config.promptTokenIDs.count, "outputCount": config.outputCount,
                "performanceQualification": false, "numericalQualification": false])
            for rank in 0..<2 {
                let p = config.peers[rank]
                let ssh = try ClusterSSHConfiguration(host: p.host, user: p.user, port: p.port,
                    knownHostsFile: URL(fileURLWithPath: p.knownHostsFile), identityFile: URL(fileURLWithPath: p.identityFile), installedDarkbloom: p.installedOwner)
                endpoints.append(try ClusterRemoteWorkerEndpoint(configuration: ssh, clusterID: config.clusterID, expectedIdentity: identity,
                    profile: template.profile, rank: rank, executionPlanSHA256: template.executionPlanSHA256,
                    lifetimeDeadlineUptimeNanoseconds: deadline, bootstrapRelay: bootstrap))
            }
            let owned = endpoints
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .init(uptimeNanoseconds: deadline))
            watchdog.setEventHandler { for endpoint in owned { endpoint.requestNativeCleanup() } }
            watchdog.resume(); timer = watchdog
            let opened = try ClusterWorkerPair(workers: endpoints, startupDeadline: min(deadline, began + UInt64(config.startupSeconds) * 1_000_000_000)); pair = opened
            guard let ready = opened.readiness else { throw QualificationFailure.invalid("Pair did not become ready") }
            // PHASE OBSERVATION BEGIN
            actualReadyCapacityBytes = endpoints.compactMap { $0.readiness?.requestCapacityBytes }
            // PHASE OBSERVATION END
            let generationDeadline = min(deadline, DispatchTime.now().uptimeNanoseconds + UInt64(config.requestSeconds) * 1_000_000_000)
            let active = try opened.reserve(requestID: id, reservation: .init(profileID: template.profile.id,
                promptTokenIDs: config.promptTokenIDs, stopTokenIDs: config.stopTokenIDs, outputCount: config.outputCount,
                chunkSize: config.chunkSize, deadlineUptimeNanoseconds: generationDeadline, capacityLimitBytes: ready.requestCapacityBytes))
            request = active
            // PHASE OBSERVATION BEGIN
            admittedReservedBytes = active.reservedBytes
            // PHASE OBSERVATION END
            try active.start { captured.accept($0) }
            await active.waitUntilRetired()
            // PHASE OBSERVATION BEGIN
            actualRequestRetired = active.isRetired
            bytesBeforeRelease = active.bytesInUse
            // PHASE OBSERVATION END
            active.releaseResources()
            // PHASE OBSERVATION BEGIN
            bytesAfterRelease = active.bytesInUse
            // PHASE OBSERVATION END
            let (tokens, reason, error) = captured.snapshot
            guard active.bytesInUse == 0, error == nil, reason != nil, !tokens.isEmpty,
                  tokens.count <= config.outputCount, config.expectedTokenIDs == nil || tokens == config.expectedTokenIDs else {
                throw QualificationFailure.invalid("Token result or retirement differs")
            }
            await opened.shutdown()
            guard endpoints.allSatisfy(\.nativeCleanupObserved) else { throw QualificationFailure.invalid("Missing actual native cleanup") }
            success = true
        } catch { failure = String(describing: error) }
        if !success {
            request?.cancel(reason: .runtimeError)
            for endpoint in endpoints { endpoint.requestNativeCleanup() }
            // The hard alarm bounds this process if the authenticated terminal is
            // unavailable. No timeout manufactures native cleanup or releases bytes.
            if let pair { await pair.shutdown() }
            else { for endpoint in endpoints { await endpoint.waitUntilNativeCleanup() } }
        }
        // Drain the authenticated lease ACK on failure too. Native retirement and
        // transport exit alone do not prove the device journal was resolved.
        let drainDeadline = min(ownerDrainLimit, DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        while !endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved), DispatchTime.now().uptimeNanoseconds < drainDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved) {
            success = false
            failure = failure ?? "Missing authenticated device lease release acknowledgment"
        }
        // An ACK precedes owner return and its final stderr. Wait for the
        // endpoint's bounded transport reaping/drain before taking the snapshot.
        let transportDrainDeadline = min(ownerDrainLimit, DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        var ownerTransportReleased: [Bool] = []
        for endpoint in endpoints {
            ownerTransportReleased.append(await endpoint.waitUntilOwnerReleased(deadline: transportDrainDeadline))
        }
        if !ownerTransportReleased.allSatisfy({ $0 }) {
            success = false
            failure = failure ?? "Missing natural owner transport exit after release acknowledgment"
        }
        if !endpoints.allSatisfy(\.diagnosticDrainComplete) {
            success = false
            failure = failure ?? "Owner diagnostic drain did not complete within bounds"
        }
        timer?.cancel()
        let (tokens, reason, error) = captured.snapshot
        var result: [String: Any] = ["schema": "owner_qualification_result_v1", "configurationSHA256": configSHA,
            "cpuQualification": cpu, "completed": success, "tokenIDs": tokens,
            "performanceQualification": false, "numericalQualification": false,
            "nativeCleanupObserved": endpoints.map(\.nativeCleanupObserved),
            "ownerDeviceLeaseReleasedObserved": endpoints.map(\.ownerDeviceLeaseReleasedObserved),
            "ownerTransportReleased": ownerTransportReleased,
            "ownerTermination": endpoints.map { qualificationOwnerTermination($0.ownerTermination) },
            "endpointDiagnosticDrainComplete": endpoints.map(\.diagnosticDrainComplete),
            "endpointDiagnosticsBase64": endpoints.map { $0.diagnosticTail.base64EncodedString() },
            "journalRelease": "Authenticated owner acknowledgment; separate remote journal/process observation remains useful",
            "elapsedControllerNanoseconds": DispatchTime.now().uptimeNanoseconds - began]
        // PHASE OBSERVATION BEGIN
        result["phaseReservationObservation"] = [
            "schema": "resident_phase_external_reservation_v1",
            "rankReadinessCapacityBytes": actualReadyCapacityBytes,
            "admittedReservedBytes": admittedReservedBytes.map { $0 as Any } ?? NSNull(),
            "bytesInUseAfterRetirementBeforeRelease": bytesBeforeRelease.map { $0 as Any } ?? NSNull(),
            "bytesInUseAfterRelease": bytesAfterRelease.map { $0 as Any } ?? NSNull(),
            "actualRequestRetired": actualRequestRetired]
        // PHASE OBSERVATION END
        if let reason { result["finishReason"] = reason }
        if let error { result["workerFailure"] = error }
        if let failure { result["failure"] = failure }
        do { try qualificationEmit(result) } catch { Darwin.exit(74) }
        alarm(0)
        if !success { Darwin.exit(1) }
    }
}
