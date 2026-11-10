import Foundation
import Testing
@testable import ProviderCore

/// DevNet 2026-11-05 (0.10.6-dev.branch.82): a Gemma 4 26B tensor-parallel pair committed under the model approval
/// `devnet/gemma-4-26b-qat-4bit/s1` and both screens said "✓ Serving … through Darkbloom", while every public request
/// got 429 `cluster_not_public … (unqualified)`. The coordinator serves the public only from a session under a
/// build-pinned approval whose release qualified the model in the session's mode family; a model approval serves its
/// owner only. A pair offered under any other approval says so instead of ✓.
@Suite("Cluster public serving check")
struct ClusterPublicServingCheckTests {
    /// The entries as DevNet's `GET /v1/cluster/approvals` listed them at 01:28Z.
    static let devnetModelApproval = #"{"id":"devnet/gemma-4-26b-qat-4bit/s1","model":"gemma-4-26b-qat-4bit","schedule":1,"not_after":"2027-01-29T00:13:54Z","generation":1,"artifact_sha256":"2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785","maximum_members":2,"maximum_records":1048576,"minimum_members":2,"maximum_plaintext":1048576,"maximum_transport_frame":1048616,"allowed_numerics_classes":[],"minimum_member_usable_bytes":1,"maximum_cumulative_plaintext":4294967296}"#
    static let releaseGemma = #"{"id":"release/0.10.6-dev.branch.83/gemma-4-26b-qat-4bit/s1","model":"gemma-4-26b-qat-4bit","generation":1,"placement_policy_sha256":"5114cad36b91f3a94bcc166a1e4a630f1a318d39ae02851f993379b37991568a","artifact_sha256":"2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785","native_runtime_sha256":"a03f1a9c955cd6e9ac9b1e12508c5e471622895d29f5d930050e07ca53b96c35","metallib_sha256":"98bab9d77dc5078ad8dd8f1fd17e8f3581415193506e4791a3c4f1ebaab614be","resource_library_sha256":"d99096e5c6fc2b0bb0be802a34986d90ff1287416cd57a360d0980ac2ce95a65","capability_sha256":"8622fb791ff78aab29a1ebbc0f8e76be6ed65da7d42e49e3bb01f9dd0198aeb4","resource_policy_sha256":"bdbcdcfe0d877d14caf4d4bcd4e59b2c0f8170bc7f7f978b83cdad991fc5d4d7","profile_sha256":"dd9a04308f713c396818e17e4c099462ae08d4506e0303ddf7083653b7f72505","schedule":1,"maximum_transport_frame":1048616,"maximum_plaintext":1048576,"maximum_records":1048576,"maximum_cumulative_plaintext":4294967296,"allowed_numerics_classes":[],"minimum_members":2,"maximum_members":2,"minimum_member_usable_bytes":1,"not_after":"2027-02-03T01:18:37Z"}"#
    static let releaseQwen35 = #"{"id":"release/0.10.6-dev.branch.82/Qwen3.5-9B/s1","model":"Qwen3.5-9B","generation":1,"placement_policy_sha256":"43643026d3df7572abe1a452de0bec7d3931f29f50dbf1ec5d59fb29d91dbf3a","artifact_sha256":"127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b","native_runtime_sha256":"db9222fe7a6fef58c4032b37dd75f89934d5049df9ac75e033b6b5a48ed1c04e","metallib_sha256":"98bab9d77dc5078ad8dd8f1fd17e8f3581415193506e4791a3c4f1ebaab614be","resource_library_sha256":"d99096e5c6fc2b0bb0be802a34986d90ff1287416cd57a360d0980ac2ce95a65","capability_sha256":"ec119a609bd346626a5dd6ef2ce4bb54e22967246d0de055eb8da696e04c50fb","resource_policy_sha256":"e1d69fba2badff4d927b0998c5132c1ada3aeb3d053a43f1dc79fd262e88fa2a","profile_sha256":"fc11ff677896ab33897564a8c2aaafe966b0e1414acf73ad15d76ee3dbfeb0d1","schedule":1,"maximum_transport_frame":1048616,"maximum_plaintext":1048576,"maximum_records":1048576,"maximum_cumulative_plaintext":4294967296,"allowed_numerics_classes":[],"minimum_members":2,"maximum_members":2,"minimum_member_usable_bytes":1,"not_after":"2027-02-03T01:01:56Z"}"#

    static func approval(_ json: String) throws -> ClusterRuntimeApproval {
        try JSONDecoder().decode(ClusterRuntimeApproval.self, from: Data(json.utf8))
    }

    @Test func aModelApprovalServesItsOwnerOnlyAndSaysWhatToDo() throws {
        let reason = try #require(ClusterPublicServingCheck.ownerOnlyReason(
            clusterApproval: Self.approval(Self.devnetModelApproval), handSaved: false, family: .tensorParallel))
        #expect(reason == "Not serving publicly: the coordinator paired both Macs but doesn't send public requests to "
            + "this pair (it runs under the model approval devnet/gemma-4-26b-qat-4bit/s1, which serves only this account's own requests)")
        #expect(ClusterOnboardingNotServing.title(reason: reason) == reason + ".")
        #expect(ClusterOnboardingNotServing.remedy(forReason: reason)
            == "Update both Macs (`\(ClusterOnboardingCommand.name) update`) to a release that approves this model for public pairs, then run `\(ClusterOnboardingCommand.name) cluster` again.")
        // A pair approval saved by hand is the same.
        #expect(ClusterPublicServingCheck.ownerOnlyReason(clusterApproval: nil, handSaved: true, family: .pipeline)?
            .contains("a pair approval saved by hand") == true)
    }

    @Test func aReleaseApprovalOfADeclaredModelInADeclaredFamilyServesThePublic() throws {
        let gemma = try Self.approval(Self.releaseGemma)
        #expect(ClusterPublicServingCheck.ownerOnlyReason(clusterApproval: gemma, handSaved: false, family: .tensorParallel) == nil)
        #expect(ClusterPublicServingCheck.ownerOnlyReason(clusterApproval: gemma, handSaved: false, family: .pipeline) == nil)
        let handOff = try #require(ClusterPublicServingCheck.ownerOnlyReason(clusterApproval: gemma, handSaved: false, family: .handOff))
        #expect(handOff.hasSuffix("(gemma-4-26b-qat-4bit is approved for public pairs in pipeline and tensor parallel only)"))
        #expect(ClusterOnboardingNotServing.remedy(forReason: handOff)
            == "Choose pipeline or tensor parallel in `\(ClusterOnboardingCommand.name) cluster`.")
    }

    @Test func aReleaseApprovalOfAModelNotApprovedForPublicPairsServesItsOwnerOnly() throws {
        let reason = try #require(ClusterPublicServingCheck.ownerOnlyReason(
            clusterApproval: Self.approval(Self.releaseQwen35), handSaved: false, family: .pipeline))
        #expect(reason.hasSuffix("(Qwen3.5-9B isn't approved for public pairs)"))
        #expect(ClusterOnboardingNotServing.remedy(forReason: reason)?.hasPrefix("Choose a model approved for public pairs") == true)
    }

    /// Both Macs' parts write the reason to their logs; the service reads it as the current run's notice, which still
    /// counts as registered for pairing.
    @Test func thePartsNoticeCarriesTheReason() throws {
        let reason = try #require(ClusterPublicServingCheck.ownerOnlyReason(
            clusterApproval: Self.approval(Self.devnetModelApproval), handSaved: false, family: .tensorParallel))
        let log = "\(ClusterLocalServing.offeredLogLine)\n\(ClusterLocalServing.logPrefix)\(reason)\n"
        #expect(ClusterLocalServing.notice(inLog: log) == reason)
        #expect(ClusterPublicServingCheck.ownerOnly(notice: reason) == reason)
        #expect(ClusterPublicServingCheck.ownerOnly(notice: ClusterLocalServing.offeredNotice) == nil)
        #expect(ClusterLocalServing.registeredOffered(notice: reason))
    }
}
