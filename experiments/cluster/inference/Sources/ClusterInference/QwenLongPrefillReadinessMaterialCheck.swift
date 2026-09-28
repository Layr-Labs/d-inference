import Foundation

/// Golden SHA values were derived independently from the retained old domain.
/// This does not invoke the native exchange or claim peer mismatch shutdown.
func checkQwenLongPrefillReadinessMaterialVectors() throws -> Int {
    let values: [(String, String, String)] = [
        (String(repeating: "a", count: 64),
         "65ef8c8a18b25335d2ab562f02a982382c18eacfdfdeb3e9f868169146afc71d",
         "181eabc1a07561e5879fd5f5908e9e417316934af73d2870f1a2b942cbcbcf0c"),
        (String(repeating: "0", count: 64),
         "8222c88091ed5bbf263c921a8cf0364ccd339e166739f5541728430cf5f0b54c",
         "d6d295fa7afdf9173b3810b22ffcf5181b6f8bbe14c2220b2375bbcc0ee739e4"),
    ]
    for (fingerprint, oldExpected, cohortExpected) in values {
        let old = QwenLongPrefillReadinessMaterial.request(agreementFingerprint: fingerprint).digest
        let cohort = QwenLongPrefillReadinessMaterial.residentCohort(agreementFingerprint: fingerprint).digest
        guard old == oldExpected, cohort == cohortExpected, old != cohort,
              old.utf8.count == 64, cohort.utf8.count == 64 else {
            throw ProbeError("Readiness material changed its legacy vector, domain or fixed size")
        }
    }
    return values.count * 2
}
