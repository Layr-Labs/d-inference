import Foundation
import Dispatch
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
@testable import ProviderCore

/// CPU metadata/wire/policy only. Ephemeral test credentials are generated
/// by the existing issuer when the parent runs this. No native Ready is made.
private final class MiMoLinkPolicyCapture: ClusterLinkWorkerTransport, @unchecked Sendable {
    let replied = DispatchSemaphore(value:0)
    private let lock = NSLock()
    private var admissions = 0
    private var credentialMatched = false
    func send(_ bytes:Data) throws { replied.signal() }
    func admitted(_ matched:Bool) { lock.withLock { admissions += 1;credentialMatched = matched } }
    var observed:(Int,Bool) { lock.withLock { (admissions,credentialMatched) } }
}

@Suite("Private MiMo installed paired-link keyed route (CPU)")
struct MiMoInstalledEncryptedLinkPolicyTests {
    @Test func candidateSelectsKeyedLinkButTextSelectionStaysLegacy() throws {
        let fixture = MiMoInstalledImagePolicyTests()
        let image = try fixture.capability(image:true), text = try fixture.capability(image:false)
        #expect(try ClusterMiMoPrivateImagePolicy.keysDataPlane(image,supported:true,sameBuild:true,hasLink:true))
        #expect(try ClusterMiMoPrivateImagePolicy.keysDataPlane(image,supported:true,sameBuild:true,hasLink:false))
        #expect(try ClusterMiMoPrivateImagePolicy.keysDataPlane(text,supported:true,sameBuild:true,hasLink:true) == false)
        #expect(try ClusterMiMoPrivateImagePolicy.keysDataPlane(text,supported:true,sameBuild:true,hasLink:false))
        for pair in [(false,false),(false,true),(true,false)] {
            #expect(throws:(any Error).self) {
                try ClusterMiMoPrivateImagePolicy.keysDataPlane(image,supported:pair.0,sameBuild:pair.1,hasLink:true)
            }
        }
        #expect(throws:(any Error).self) {
            try ClusterMiMoPrivateImagePolicy.keysDataPlane(image,supported:true,sameBuild:true,hasLink:true,selectionOverride:false)
        }
    }

    @Test func openCarriesOnlyItsOwnEpochRankCredentialAndNilTextBytesStayAbsent() throws {
        let fixture = MiMoInstalledImagePolicyTests()
        let image = try fixture.capability(image:true), text = try fixture.capability(image:false)
        let epoch = UUID(), lines = try ClusterDataPlaneLaunch.sessionCredentialLines(epoch:epoch)
        var object:[String:Any] = ["version":ClusterLinkWorkerWire.version,"kind":"open","epoch":epoch.uuidString,
            "session":UUID().uuidString,"sequence":0,"clusterID":"cpu-wire-policy",
            "rank":1,"planSHA256":image.partitions[0].planSHA256,"remainingNanoseconds":1_000_000_000]
        let legacy = try ClusterLinkWorkerWire.decode(JSONSerialization.data(withJSONObject:object))
        #expect(legacy.dataPlaneTrust == nil)
        let legacyBytes = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        #expect(try legacy.encoded() == legacyBytes)
        let plain = try JSONSerialization.jsonObject(with:legacy.encoded()) as! [String:Any]
        #expect(plain["dataPlaneTrust"] == nil)
        object["dataPlaneTrust"] = lines[1].base64EncodedString()
        let keyed = try ClusterLinkWorkerWire.decode(JSONSerialization.data(withJSONObject:object))
        let retained = keyed.dataPlaneTrust == lines[1]
        let roundTrip = try ClusterLinkWorkerWire.decode(keyed.encoded()).dataPlaneTrust == lines[1]
        let forwarded = try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(image,line:keyed.dataPlaneTrust,
            epoch:epoch,rank:1) == lines[1]
        #expect(retained && roundTrip && forwarded)
        #expect(try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(text,line:nil,epoch:epoch,rank:1) == nil)
        #expect(throws:(any Error).self) {
            try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(image,line:nil,epoch:epoch,rank:1)
        }
        #expect(throws:(any Error).self) {
            try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(text,line:lines[1],epoch:epoch,rank:1)
        }
        for bad in [lines[0],Data(repeating:0,count:4097),Data("invalid\n".utf8)] {
            object["dataPlaneTrust"] = bad.base64EncodedString()
            #expect(throws:(any Error).self) { try ClusterLinkWorkerWire.decode(JSONSerialization.data(withJSONObject:object)) }
        }
        #expect(throws:(any Error).self) {
            try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(image,line:lines[1],epoch:UUID(),rank:1)
        }
        let wrongKind:[String:Any] = ["version":ClusterLinkWorkerWire.version,"kind":"accepted","epoch":epoch.uuidString,
            "session":UUID().uuidString,"sequence":0,"dataPlaneTrust":lines[1].base64EncodedString()]
        #expect(throws:(any Error).self) { try ClusterLinkWorkerWire.decode(JSONSerialization.data(withJSONObject:wrongKind)) }
        // A successfully decoded control open is deliberately not a native
        // handshake, load, encrypted Ready or actual image quality assertion.
    }
    @Test func genericFollowerRefusesCredentialUnlessItsOwnPolicyOptsIn() throws {
        let image = try MiMoInstalledImagePolicyTests().capability(image:true)
        let epoch = UUID(), lines = try ClusterDataPlaneLaunch.sessionCredentialLines(epoch:epoch)
        let object:[String:Any] = ["version":ClusterLinkWorkerWire.version,"kind":"open","epoch":epoch.uuidString,
            "session":UUID().uuidString,"sequence":0,"clusterID":"cpu-wire-policy","rank":1,
            "planSHA256":image.partitions[0].planSHA256,"remainingNanoseconds":1_000_000_000,
            "dataPlaneTrust":lines[1].base64EncodedString()]
        let bytes = try JSONSerialization.data(withJSONObject:object)
        for enabled in [false,true] {
            let capture = MiMoLinkPolicyCapture()
            let server = ClusterLinkWorkerServer(transport:capture,clusterID:"cpu-wire-policy",rank:1,
                bootstrapProfile:nil,acceptsDataPlaneTrust:enabled,admit:{ open in
                    capture.admitted(open.dataPlaneTrust == lines[1])
                    throw ClusterLinkWorkerError.invalid("CPU policy fixture stops before owner launch")
                })
            server.deliver(bytes)
            #expect(capture.replied.wait(timeout:.now()+2) == .success)
            let result = capture.observed
            #expect(result.0 == (enabled ? 1 : 0))
            #expect(result.1 == enabled)
            #expect(server.served == 0 && !server.busy)
            server.stop()
        }
        // No owner, process, native group or Ready was created in either case.
    }

}
