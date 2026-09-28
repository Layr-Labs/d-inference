import Foundation

func checkObservedLegacy(_ checks: inout QwenObservedFixtureChecks) throws {
    let records: [QwenDenseObservedSourceTensor] = [
        fixtureObserved(.init(name: "z", shape: [2], sourceDType: "F16", byteCount: 4)),
        fixtureObserved(.init(name: "a", shape: [2], sourceDType: "U32", byteCount: 8)),
        fixtureObserved(.init(name: "b", shape: [2], sourceDType: "BF16", byteCount: 4)),
        fixtureObserved(.init(name: "c", shape: [2], sourceDType: "F32", byteCount: 8)),
    ]
    for purpose in [QwenDenseLegacySourcePurpose.diagnostic, .layerStage] {
        for convert in [false, true] {
            let actual = try QwenDenseObservedSourceValidation.validateLegacy(records, convertBF16: convert, purpose: purpose)
            let expectedLayout = ["a:uint32:[2]", "b:bfloat16:[2]", "c:float32:[2]", "z:\(convert ? "bfloat16" : "float16"):[2]"]
            try checks.require("legacy layout/bytes \(purpose)/\(convert)", actual.sourceBytes == 24 &&
                actual.largestSourceBytes == 8 && actual.tensors.map { $0.canonical.name } == ["a", "b", "c", "z"] &&
                actual.expectedLayoutSHA256 == sha256(Data(expectedLayout.joined(separator: "\n").utf8)) &&
                actual.registeredProfileFingerprint == nil && !actual.runtimeExecutionAuthorized)
        }
        let base = records[0]
        let invalid: [(String, [QwenDenseObservedSourceTensor])] = [
            ("empty", []), ("duplicate", records + [base]),
            ("multiple parts", [fixtureObserved(base.canonical, parts: 2)]),
            ("wrong shape", [fixtureObserved(base.canonical, expectedShape: [1, 2])]),
            ("missing shape", [.init(canonical: base.canonical, sourcePartCount: 1, preparedExpectedShape: nil, constructorParameterIsPacked: false)]),
            ("missing constructor", [.init(canonical: base.canonical, sourcePartCount: 1, preparedExpectedShape: [2], constructorParameterIsPacked: nil)]),
            ("packed class", [fixtureObserved(base.canonical, packed: true)]),
            ("unsupported dtype", [fixtureObserved(.init(name: "x", shape: [2], sourceDType: "BOOL", byteCount: 2))]),
            ("zero bytes", [fixtureObserved(.init(name: "x", shape: [2], sourceDType: "BF16", byteCount: 0))]),
            ("host bound", [fixtureObserved(.init(name: "x", shape: [268435457], sourceDType: "BF16", byteCount: 536870914))]),
        ]
        for (label, values) in invalid {
            try checks.reject("legacy \(purpose) " + label) {
                _ = try QwenDenseObservedSourceValidation.validateLegacy(values, convertBF16: true, purpose: purpose)
            }
        }
        // Large byte counts are scalar metadata only; these fixtures allocate no payloads.
        let maximum = (0..<12).map { fixtureObserved(.init(name: "tensor\($0)", shape: [268435456], sourceDType: "BF16", byteCount: 536870912)) }
        let admitted = try QwenDenseObservedSourceValidation.validateLegacy(maximum, convertBF16: true, purpose: purpose)
        try checks.require("legacy exact fixed ceilings \(purpose)", admitted.sourceBytes == 6_442_450_944 && admitted.largestSourceBytes == 536_870_912)
        try checks.reject("legacy source bound \(purpose)") {
            _ = try QwenDenseObservedSourceValidation.validateLegacy(maximum + [fixtureObserved(.init(name: "last", shape: [1], sourceDType: "BF16", byteCount: 2))], convertBF16: true, purpose: purpose)
        }
    }
}
