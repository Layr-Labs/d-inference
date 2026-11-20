import CryptoKit
import DarkbloomClusterSecurity
import Foundation

enum LabRecordChecks {
    static func run() throws -> Data {
        let h = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let base = LabRecordJob(schema: "lab_authenticated_rdma_component_v1", identityKind: "ssh_host_key_lab_only",
            runID: "03c3eabb-e00f-4ac5-92b2-d86d838ac927", rank: 0, payloadBytes: 8192, warmups: 3, measurements: 20,
            timeoutSeconds: 120, hostKeySHA256: [h, other], nativeBuildSHA256: [h,h], sourceSnapshotSHA256: h,
            mlxArtifactSHA256: h, secretCommitmentSHA256: h, expectedHardware: ["fixture","fixture"], expectedOSBuild: ["fixture","fixture"])
        try base.validate()
        let raw = try canonicalJSONData(base)
        guard try LabRecordJob.decode(raw).scopeSHA256 == base.scopeSHA256, base.frameCeiling == 8232,
              base.rounds == 23, Set(LabRecordJob.modes).count == 4 else { throw ProbeError("Lab positive contract failed") }
        func altered(_ key: String, _ value: Any) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]; object[key] = value
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        for (key, value) in [("identityKind", "verified_pair" as Any), ("rank", 2 as Any), ("payloadBytes", 700 as Any), ("warmups", 0 as Any)] {
            var rejected = false
            do { _ = try LabRecordJob.decode(altered(key,value)) } catch { rejected = true }
            guard rejected else { throw ProbeError("Lab invalid contract accepted") }
        }
        let rank1 = try LabRecordJob.decode(altered("rank",1))
        guard rank1.scopeSHA256 == base.scopeSHA256 else { throw ProbeError("Lab common transcript differs by rank") }
        let wire = try LabRecordMeasurements.recordBinding(base,"actual-wire")
        let local = try LabRecordMeasurements.recordBinding(base,"local-codec/rank0")
        guard wire.planSHA256 != local.planSHA256, wire.membershipTranscriptSHA256 != local.membershipTranscriptSHA256 else { throw ProbeError("Lab channel domain separation failed") }
        let key = SymmetricKey(data: Data(repeating: 0x63,count:32)) // public CPU fixture only
        let payload = Data(repeating:0x51,count:32)
        let limits = try ClusterRecordLimits(maximumPlaintextBytes:32,maximumRecordsPerDirection:2,maximumCumulativePlaintextBytesPerDirection:64)
        let sender = try ClusterAuthenticatedRecordChannel(sessionKey:key,binding:wire,localRank:0,limits:limits)
        let receiver = try ClusterAuthenticatedRecordChannel(sessionKey:key,binding:wire,localRank:1,limits:limits)
        defer {sender.invalidate();receiver.invalidate()}
        let expected = try LabRecordMeasurements.context(base,"fixture")
        let sealed = try sender.seal(payload,context:expected)
        guard try receiver.open(sealed,expecting:expected)==payload else {throw ProbeError("Lab actual codec roundtrip failed")}
        var replayRejected=false
        do {_ = try receiver.open(sealed,expecting:expected)} catch {replayRejected = (error as? ClusterRecordError) == .sequenceMismatch}
        guard replayRejected, !receiver.status.active else {throw ProbeError("Lab replay did not poison receiver")}
        return try JSONSerialization.data(withJSONObject:["schema":"lab_record_local_contract_v1","passed":true,
            "groups":["valid-job","invalid-identity","invalid-rank","invalid-size","invalid-rounds",
                      "rank-common-transcript","channel-domain-separation","real-codec-replay"],
            "nativeGroupExecuted":false,"publicFixtureKeyOnly":true],options:[.sortedKeys])
    }
}
