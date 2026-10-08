import Foundation

/// Only named readiness domains can create a fixed-size SHA material.
/// No received string, array or unchecked digest initializer is exposed.
struct QwenLongPrefillReadinessMaterial: Equatable {
    let digest: String
    private init(digest: String) { self.digest = digest }

    static func request(agreementFingerprint: String) -> Self {
        .init(digest: sha256(Data(("qwen-profiled-prefill-readiness-v1|" + agreementFingerprint).utf8)))
    }

    static func residentCohort(agreementFingerprint: String) -> Self {
        .init(digest: sha256(Data(("qwen-long-prefill-resident-cohort-readiness-v1|" + agreementFingerprint).utf8)))
    }

    static func generation(agreementFingerprint: String) -> Self {
        .init(digest: sha256(Data(("qwen-stage-generation-readiness-v1|" + agreementFingerprint).utf8)))
    }
}
