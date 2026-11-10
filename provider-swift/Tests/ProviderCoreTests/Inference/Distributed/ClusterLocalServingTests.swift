import Foundation
import Testing
@testable import ProviderCore

/// Pilot blocker: a pair whose coordinator cannot take its cluster member role
/// (unreachable, or a coordinator that predates the role) serves on the
/// leader's local API only, and says so in one plain line. A refusal of this
/// member is never read as "unsupported".
@Suite("Cluster local serving")
struct ClusterLocalServingTests {
    @Test func onlyAnUnreachableOrRoleUnawareCoordinatorServesLocally() {
        #expect(ClusterLocalServing.servesLocally(after: ClusterMemberControlError.roleUnsupported))
        #expect(ClusterLocalServing.servesLocally(after: ClusterMemberControlError.coordinatorUnreachable))
        // A refusal of this member or pairing, a dropped control connection, a malformed
        // membership claim and a stop are never a reason to serve without the coordinator.
        for error in [ClusterMemberControlError.negotiationFailed, .connectionEnded, .invalidMembership, .incompatibleConfiguration] {
            #expect(!ClusterLocalServing.servesLocally(after: error), "\(error)")
        }
        #expect(!ClusterLocalServing.servesLocally(after: CancellationError()))
        #expect(!ClusterLocalServing.servesLocally(after: URLError(.timedOut)))
    }

    /// The part's log keeps earlier runs: only the current run's line counts. Every serving start writes one of the two.
    @Test func theServiceReadsTheCurrentRunsNoticeFromThePartsLog() {
        let banner = "darkbloom 9.9.9 (local / distributed)"
        let notice = ClusterLocalServing.logLine
        let registered = ClusterLocalServing.registeredLogLine
        #expect(ClusterLocalServing.notice(inLog: "\(banner)\nModel: m\n\(notice)\nListening on 127.0.0.1:8000\n") == ClusterLocalServing.notice)
        // A later run that registered with the coordinator.
        #expect(ClusterLocalServing.notice(inLog: "\(notice)\nError: stopped\n\(banner)\n\(registered)\nModel: m\n") == nil)
        // A later local-only run after a registered one.
        #expect(ClusterLocalServing.notice(inLog: "\(registered)\nError: stopped\n\(notice)\n") == ClusterLocalServing.notice)
        #expect(ClusterLocalServing.notice(inLog: "") == nil)
        #expect(ClusterLocalServing.notice(inLog: "Error: The coordinator could not be reached\n") == nil)
    }

    /// DevNet 2026-11-05 (0.10.6-dev.branch.81): a Gemma pair offered under `devnet/gemma-4-26b-qat-4bit/s1` waited
    /// 11 minutes on "waiting for the coordinator to pair both Macs". The coordinator refused it on every pass
    /// (`serves_model`): its model catalog had no row for the model. A part offered for a model the catalog does not
    /// list says so, and that notice replaces the offered one as the current run's.
    @Test func aPartOfferedForAModelTheCoordinatorsCatalogDoesNotListSaysSo() {
        let model = "gemma-4-26b-qat-4bit"
        #expect(ClusterLocalServing.catalogRefusal(modelID: model, catalogIDs: ["Qwen3.5-9B", "glm-5.3-flash"])
            == "The coordinator does not pair Macs for gemma-4-26b-qat-4bit: its model catalog does not list it")
        #expect(ClusterLocalServing.catalogRefusal(modelID: model, catalogIDs: [model, "glm-5.3-flash"]) == nil)
        // An unread catalog is no evidence: nothing is said.
        #expect(ClusterLocalServing.catalogRefusal(modelID: model, catalogIDs: []) == nil)
        let refusal = ClusterLocalServing.catalogRefusal(modelID: model, catalogIDs: ["glm-5.3-flash"])!
        let log = "\(ClusterLocalServing.offeredLogLine)\n\(ClusterLocalServing.logPrefix)\(refusal)\n"
        #expect(ClusterLocalServing.notice(inLog: log) == refusal)
        #expect(ClusterLocalServing.pairRefusal(notice: refusal) == refusal)
        #expect(ClusterLocalServing.pairRefusal(notice: ClusterLocalServing.offeredNotice) == nil)
        #expect(ClusterLocalServing.pairRefusal(notice: nil) == nil)
        // A later run that registered without the refusal reads as offered again.
        #expect(ClusterLocalServing.notice(inLog: log + ClusterLocalServing.offeredLogLine + "\n") == ClusterLocalServing.offeredNotice)
        // Only the part's own wording is taken from its log.
        #expect(ClusterLocalServing.notice(inLog: "\(ClusterLocalServing.logPrefix)The coordinator does not pair Macs for \u{1B}[2J: x\n") == nil)
    }

    @Test func theReadyScreenAddsTheNoticeAfterTheAPILine() {
        let ready = ClusterOnboardingReady(servedBy: "this Mac", port: 8000, deployment: "Serving M across both Macs: pipeline",
                                           notice: ClusterLocalServing.notice)
        #expect(ready.lines(model: "M") == ["Serving M across both Macs: pipeline", "API at http://localhost:8000 on this Mac",
                                            ClusterLocalServing.notice])
        let publicReady = ClusterOnboardingReady(servedBy: "this Mac", port: 8000)
        #expect(publicReady.lines(model: "M").count == 2)
        // A ready answer from an older build (no notice field) still decodes.
        let old = #"{"servedBy":"this Mac","port":8000}"#
        #expect((try? JSONDecoder().decode(ClusterOnboardingReady.self, from: Data(old.utf8)))?.notice == nil)
    }

    @Test func theServiceStatusCarriesTheNoticeAndOldStatusesStillDecode() throws {
        var child = ClusterServiceStatus.Child(running: true, starts: 1, lastEnd: nil, restartInSeconds: nil, lastError: nil)
        child.notice = ClusterLocalServing.notice
        let data = try JSONEncoder().encode(child)
        #expect(try JSONDecoder().decode(ClusterServiceStatus.Child.self, from: data).notice == ClusterLocalServing.notice)
        let old = #"{"running":true,"starts":1}"#
        #expect(try JSONDecoder().decode(ClusterServiceStatus.Child.self, from: Data(old.utf8)).notice == nil)
    }
}
