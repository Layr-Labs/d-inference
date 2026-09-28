import Foundation

func checkQwenLongPrefillResidentCohortAgreement() throws {
    let fixture = try QwenLongPrefillResidentCohortFixture()
    let first = try fixture.request(1), middle = try fixture.request(2, prompt: fixture.promptB)
    let last = try fixture.request(3), requests = [first, middle, last]
    let options = try fixture.options(first)
    let agreement = try QwenLongPrefillResidentCohortAgreement(
        options: options, requests: requests, warmupCount: 1)
    var accepted: [String] = [], distinct: [String] = [], rejected: [String] = []
    func require(_ name: String, _ condition: Bool) throws {
        guard condition else { throw ProbeError("Resident cohort agreement fixture failed: " + name) }
        accepted.append(name)
    }
    func different(_ name: String, _ candidate: QwenLongPrefillResidentCohortAgreement) throws {
        guard candidate.fingerprint != agreement.fingerprint,
              candidate.descriptor != agreement.descriptor else {
            throw ProbeError("Resident cohort failed to distinguish: " + name)
        }
        distinct.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Resident cohort agreement admitted: " + name)
    }
    func make(_ values: [QwenLongPrefillResidentRankRequest], warmups: Int = 1,
              changed: Options? = nil) throws -> QwenLongPrefillResidentCohortAgreement {
        try .init(options: changed ?? options, requests: values, warmupCount: warmups)
    }

    let repeated = try make(requests)
    try require("deterministic descriptor and fingerprint", repeated.fingerprint == agreement.fingerprint &&
        canonicalJSONData(repeated.descriptor) == canonicalJSONData(agreement.descriptor))
    let entries = agreement.descriptor.requests
    try require("ordered A B A binds fresh full identities and warmups",
        entries.map(\.epoch) == requests.map(\.epoch) && entries.map(\.excludedWarmup) == [true, false, false] &&
        entries.map(\.recordedRequestFingerprint) == requests.map { $0.local.request.fingerprint } &&
        first.local.promptTokenIDsSHA256 == last.local.promptTokenIDsSHA256 &&
        first.local.request.fingerprint != last.local.request.fingerprint)
    let maximum = try (1...16).map { try fixture.request($0) }
    let maximumAgreement = try make(maximum, warmups: 15)
    try require("maximum cohort stays within metadata bound", maximumAgreement.descriptor.requestCount == 16 &&
        canonicalJSONData(maximumAgreement.descriptor).count <= QwenLongPrefillResidentCohortAgreement.maximumEncodedBytes)
    let single = try make([first], warmups: 0)
    try require("one fresh measured request", single.descriptor.requests.count == 1 &&
        single.descriptor.requests[0].excludedWarmup == false)
    let halfRequests = try [fixture.request(1, cut: nil),
        fixture.request(2, prompt: fixture.promptB, cut: nil), fixture.request(3, cut: nil)]
    let half = try make(halfRequests, changed: fixture.options(halfRequests[0], cut: nil))
    let explicitHalf = try make(halfRequests, changed: fixture.options(halfRequests[0], cut: 16))
    try require("omitted and explicit historical half select the same cohort", half.descriptor == explicitHalf.descriptor &&
        half.fingerprint == explicitHalf.fingerprint)
    var changed = options
    changed.modelDirectory = URL(fileURLWithPath: "other-unused-model")
    changed.tokensFile = URL(fileURLWithPath: "other-unused-prompt")
    let otherPaths = try make(requests, changed: changed)
    try require("rank-local paths are absent from common agreement", otherPaths.fingerprint == agreement.fingerprint)

    try different("later logical prompt", make([first, fixture.request(2), last]))
    try different("later fresh UUID and epoch", make([first, fixture.request(4, prompt: fixture.promptB), last]))
    try different("later request ordering", make([first, last, middle]))
    try different("request count", make([first, middle]))
    try different("warmup boundary", make(requests, warmups: 2))
    try different("selected Plan", half)
    try different("scheduling policy", make(requests,
        changed: fixture.options(first, policy: "prompt_lookahead_one_v1")))
    let encodedDifferently = try fixture.request(2, prompt: fixture.promptB + Data([10]))
    guard encodedDifferently.local.request.fingerprint == middle.local.request.fingerprint,
          encodedDifferently.local.promptFileSHA256 != middle.local.promptFileSHA256 else {
        throw ProbeError("Raw prompt identity fixture changed its logical token history")
    }
    try different("same tokens with different raw prompt bytes", make([first, encodedDifferently, last]))

    try reject("empty cohort") { _ = try make([], warmups: 0) }
    try reject("seventeenth request") { _ = try make(maximum + [fixture.request(17)]) }
    try reject("negative warmups") { _ = try make(requests, warmups: -1) }
    try reject("no measured request") { _ = try make(requests, warmups: 3) }
    try reject("reused epoch and UUID") { _ = try make([first, first]) }
    try reject("malformed epoch") {
        _ = try make([first, .init(epoch: String(repeating: "A", count: 32), local: middle.local)])
    }
    try reject("epoch differs from request UUID") {
        _ = try make([first, .init(epoch: last.epoch, local: middle.local)])
    }
    changed = options; changed.epoch = middle.epoch
    try reject("initial epoch differs from options") { _ = try make(requests, changed: changed) }
    changed = options; changed.longPromptSHA256 = middle.local.promptFileSHA256
    try reject("initial raw prompt differs from options") { _ = try make(requests, changed: changed) }
    try reject("later Plan changes") { _ = try make([first, fixture.request(2, cut: nil)]) }
    changed = options; changed.stageCut = nil
    try reject("nil cut cannot carry unequal plan") { _ = try make(requests, changed: changed) }
    try reject("explicit cut cannot carry half plan") { _ = try make(halfRequests) }
    changed = options; changed.prefillPhaseTraceFile = URL(fileURLWithPath: "unused-phase")
    try reject("phase trace remains disabled") { _ = try make(requests, changed: changed) }
    changed = options; changed.prefillOwnerTraceFile = URL(fileURLWithPath: "unused-owner")
    try reject("owner trace remains disabled") { _ = try make(requests, changed: changed) }
    changed = options; changed.expectedArtifactAggregateSHA256 = String(repeating: "0", count: 64)
    try reject("source aggregate differs from options") { _ = try make(requests, changed: changed) }
    changed = options; changed.stagePrefillPolicy = nil
    try reject("missing scheduling policy") { _ = try make(requests, changed: changed) }
    changed = options; changed.stageLogitsDType = "float32"
    try reject("changed logits precision") { _ = try make(requests, changed: changed) }

    let vectors = try checkQwenLongPrefillReadinessMaterialVectors()
    guard accepted.count == 6, distinct.count == 8, rejected.count == 17, vectors == 4 else {
        throw ProbeError("Resident cohort agreement fixture case count changed")
    }
    struct Result: Encodable {
        let kind = "qwen_long_prefill_resident_cohort_agreement_check", cpuOnly = true
        let acceptedFixtures = 6, distinctPeerAgreementFixtures = 8, rejectedFixtures = 17
        let readinessMaterialVectors = 4
        let accepted: [String], distinctPeerAgreements: [String], rejected: [String]
        let actualOptionsAndLocalAdmissionUsed = true
        let collectiveConstructed = false, modelConstructed = false
        let readinessExchangeExecuted = false, residentModelReuseQualified = false
    }
    try emitJSON(Result(accepted: accepted, distinctPeerAgreements: distinct, rejected: rejected))
}
