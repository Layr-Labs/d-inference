import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// UNRUN private draft. Depends on Hume's independently closed Completed test
/// fixture. Actual metadata-only fixture child exit is required; there is no
/// Completed/Response injection. The peer below is a genuine signed fixture
/// authorization, not proof of a second installed quote or a live native run.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_INPUT"] != nil
    || ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationNativeStartTests {
    typealias N = GLM5NextCalibrationNativeStart
    typealias D = GLM5NextCalibrationDocument
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias C = GLM5NextCalibrationInstalledQuote

    struct Fixture {
        let fixture: GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture
        let completed: C.Completed
        let local: GLM5NextCalibrationAuthorizer.Authorized
        let peer: GLM5NextCalibrationAuthorizer.Authorized
        let now: Int64
        var deadline: UInt64 { DispatchTime.now().uptimeNanoseconds + 1_000_000_000 }
        init() throws {
            let fixture = try GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture()
            // Select the finite FP32 lane before the genuine metadata child.
            var input = try GLM5NextCalibrationNativeDocumentsTests.Fixture.object(
                JSONDecoder().decode(C.Input.self, from: Data(contentsOf: fixture.input)))
            var environment = input["environment"] as! [String: String]
            environment["MLX_ENABLE_TF32"] = "0"; input["environment"] = environment
            var request = input["request"] as! [String: Any]
            var selection = request["selection"] as! [String: Any]
            var facts = selection["environment"] as! [String: Any]
            facts["variableSHA256"] = environment.filter {
                $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")
            }.mapValues(GLM5NextCalibrationLaunch.digest)
            selection["environment"] = facts; request["selection"] = selection; input["request"] = request
            try GLM5NextCalibrationNativeDocumentsTests.Fixture.json(input).write(to: fixture.input)
            let completed = try fixture.complete()
            let now = Int64(Date().timeIntervalSince1970)
            let body = try GLM5NextCalibrationQuoteAuthorizer.experimentBody(response: completed.responseData,
                authorized: completed.authorized, now: now, expectedVocabularySize: completed.pinnedVocabularySize)
            let local = try GLM5NextCalibrationAuthorizer.authorize(body, identity: completed.authorized.identity,
                rank: body.selection.rank, now: now, expectedVocabularySize: completed.pinnedVocabularySize,
                memberIdentity: completed.pair.localIdentity, peerIdentity: completed.pair.peerIdentity,
                appSHA256: completed.authorized.request.appSHA256, signer: completed.pair.signer,
                verifySelection: { try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) })
            var other = try GLM5NextCalibrationNativeDocumentsTests.Fixture.object(body)
            var p = other["selection"] as! [String: Any]; p["rank"] = 1 - body.selection.rank
            var e = p["environment"] as! [String: Any]
            e["binarySHA256"] = String(repeating: "a", count: 64)
            var vars = e["variableSHA256"] as! [String: String]
            vars[GLM5NextCalibrationLaunch.appIdentityVariable] = GLM5NextCalibrationLaunch.digest(String(repeating: "a", count: 64))
            vars[GLM5NextCalibrationLaunch.peerIdentityVariable] = GLM5NextCalibrationLaunch.digest(
                GLM5NextCalibrationLaunch.peerFingerprint(completed.pair.localIdentity))
            e["variableSHA256"] = vars; p["environment"] = e; other["selection"] = p
            let peerBody = try JSONDecoder().decode(D.Body.self, from: GLM5NextCalibrationNativeDocumentsTests.Fixture.json(other))
            let peer = try GLM5NextCalibrationAuthorizer.authorize(peerBody, identity: completed.authorized.identity,
                rank: peerBody.selection.rank, now: now, expectedVocabularySize: completed.pinnedVocabularySize,
                memberIdentity: completed.pair.peerIdentity, peerIdentity: completed.pair.localIdentity,
                appSHA256: String(repeating: "a", count: 64), signer: fixture.pairing.peer, verifySelection: {})
            self.fixture = fixture; self.completed = completed; self.now = now; self.local = local; self.peer = peer
        }
        func admission(local override: GLM5NextCalibrationAuthorizer.Authorized? = nil) throws -> N.Admission {
            try N.admit(completed: completed, localAuthorization: override ?? local,
                peerDocument: peer.document, now: now, deadline: deadline)
        }
        func peerStart(_ admission: N.Admission, common: ClusterNativeAuthorizationCommon? = nil,
                       incarnation: UUID = UUID()) throws -> ClusterNativeAuthorizationStart {
            try .init(common: common ?? admission.common, rank: peer.body.selection.rank,
                ownerIncarnation: incarnation, leaseID: UUID(), launchID: UUID())
        }
    }
    @Test func actualCompletedAdmissionCommitsOnceAcrossCopiesAndValidatesExactLocalStart() throws {
        let f = try Fixture()
        var admission = try f.admission(), copied = admission
        let peerStart = try f.peerStart(admission)
        let committed = try admission.commit(peerStart: peerStart, now: f.now, deadline: f.deadline)
        #expect(committed.starts.map(\.rank) == [0, 1])
        #expect(committed.identity == f.completed.authorized.identity)
        #expect(committed.profile == f.local.body.binding.profile.workerProfile)
        #expect(committed.executionPlanSHA256 == f.completed.response.binding.executionPlanSHA256)
        try committed.validateLocalStart(admission.localStart, now: f.now)
        #expect(throws: ClusterNativeKeyError.alreadyConsumed) {
            try copied.commit(peerStart: peerStart, now: f.now, deadline: f.deadline)
        }
        let changed = try ClusterNativeAuthorizationStart(common: admission.common, rank: committed.localRank,
            ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        #expect(throws: (any Error).self) { try committed.validateLocalStart(changed, now: f.now) }
        #expect(throws: (any Error).self) {
            try committed.validateLocalStart(admission.localStart, now: f.local.body.selection.expiresUnixSeconds)
        }
    }
    @Test func aGenuinelySignedLocalBodyCannotReplaceCompletedResources() throws {
        let f = try Fixture()
        var object = try GLM5NextCalibrationNativeDocumentsTests.Fixture.object(f.local.body)
        var auth = object["authorization"] as! [String: Any]
        auth["workspaceNativeAllowanceBytes"] = f.local.body.authorization.workspaceNativeAllowanceBytes + 1
        object["authorization"] = auth
        let changedBody = try JSONDecoder().decode(D.Body.self,
            from: GLM5NextCalibrationNativeDocumentsTests.Fixture.json(object))
        let changed = try GLM5NextCalibrationAuthorizer.authorize(changedBody, identity: f.local.identity,
            rank: f.local.body.selection.rank, now: f.now, expectedVocabularySize: f.completed.pinnedVocabularySize,
            memberIdentity: f.completed.pair.localIdentity, peerIdentity: f.completed.pair.peerIdentity,
            appSHA256: f.completed.authorized.request.appSHA256, signer: f.completed.pair.signer, verifySelection: {})
        #expect(throws: (any Error).self) { try f.admission(local: changed) }
    }
    @Test func commitRechecksFilesPairDeadlineAndAllSixNonces() throws {
        let f = try Fixture()
        var admission = try f.admission()
        let wrongRank = try ClusterNativeAuthorizationStart(common: admission.common, rank: admission.localStart.rank,
            ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        #expect(throws: (any Error).self) { try admission.commit(peerStart: wrongRank, now: f.now, deadline: f.deadline) }
        let collision = try f.peerStart(admission, incarnation: admission.localStart.leaseID)
        #expect(throws: (any Error).self) { try admission.commit(peerStart: collision, now: f.now, deadline: f.deadline) }
        let differentCommon = try GLM5NextCalibrationNativeCodecTests().common()
        let differentStart = try f.peerStart(admission, common: differentCommon)
        #expect(throws: (any Error).self) { try admission.commit(peerStart: differentStart, now: f.now, deadline: f.deadline) }
        let peer = try f.peerStart(admission)
        #expect(throws: (any Error).self) {
            try admission.commit(peerStart: peer, now: f.local.body.selection.expiresUnixSeconds, deadline: f.deadline)
        }
        #expect(throws: (any Error).self) {
            try admission.commit(peerStart: peer, now: f.now, deadline: DispatchTime.now().uptimeNanoseconds - 1)
        }
        try Data("changed task-private worker".utf8).write(to: f.fixture.worker)
        #expect(throws: (any Error).self) { try admission.commit(peerStart: peer, now: f.now, deadline: f.deadline) }
    }
    @Test func actualRetainedPairChangeBetweenAdmissionAndCommitRefuses() throws {
        let f = try Fixture()
        var admission = try f.admission()
        let peer = try f.peerStart(admission)
        try f.fixture.pairing.write()
        #expect(throws: (any Error).self) { try admission.commit(peerStart: peer, now: f.now, deadline: f.deadline) }
    }
}
