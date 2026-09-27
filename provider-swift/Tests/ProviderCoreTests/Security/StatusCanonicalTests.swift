import Foundation
import Testing
@testable import ProviderCore

// Keep these exact bytes aligned with status_canonical_mixed_case_test.go.
// The production-model vector originates in Jake McAllister's PR #826.
private struct StatusCanonicalVector {
    let name: String
    let input: StatusCanonicalInput
    let expected: String
}

private func statusCanonicalVectors() -> [StatusCanonicalVector] {
    [
        StatusCanonicalVector(
            name: "production-model-ids",
            input: StatusCanonicalInput(nonce: "n", timestamp: "t", modelHashes: [
                "Qwen3.5-9B": "127de76b4ef82b7a",
                "gemma-4-26b-qat-4bit": "2468a0cb3049a871",
                "qwen3.6-35b-a3b-vl-mtp-mxfp8": "d932e96b00404b05",
            ]),
            expected: #"{"model_hashes":{"Qwen3.5-9B":"127de76b4ef82b7a","gemma-4-26b-qat-4bit":"2468a0cb3049a871","qwen3.6-35b-a3b-vl-mtp-mxfp8":"d932e96b00404b05"},"nonce":"n","timestamp":"t"}"#
        ),
        StatusCanonicalVector(
            name: "both-nested-maps",
            input: StatusCanonicalInput(nonce: "n", timestamp: "t", templateHashes: [
                "template2": "02", "Template10": "10", "template10": "11",
                "_Template": "12", "-template": "13", "Z": "14", "a": "15",
            ], modelHashes: [
                "model2": "22", "Model10": "10", "model10": "11",
                "A.Model": "01", "a/model": "02", "_model": "03", "-model": "04",
            ]),
            expected: #"{"model_hashes":{"-model":"04","A.Model":"01","Model10":"10","_model":"03","a/model":"02","model10":"11","model2":"22"},"nonce":"n","template_hashes":{"-template":"13","Template10":"10","Z":"14","_Template":"12","a":"15","template10":"11","template2":"02"},"timestamp":"t"}"#
        ),
        StatusCanonicalVector(
            name: "template-filename-escaping",
            // Model IDs are ASCII-restricted, but RuntimeHashReporter uses
            // .jinja filename stems as template keys without that restriction.
            input: StatusCanonicalInput(nonce: "abc+/=", timestamp: "t", templateHashes: [
                "é\"\\\t\n<>&": "d00d", "模板": "beef", "Z": "00",
            ]),
            expected: #"{"nonce":"abc+/=","template_hashes":{"Z":"00","é\"\\\t\n<>&":"d00d","模板":"beef"},"timestamp":"t"}"#
        ),
        StatusCanonicalVector(
            name: "template-unicode-separators",
            input: StatusCanonicalInput(nonce: "n", timestamp: "t", templateHashes: [
                "line\u{2028}paragraph\u{2029}": "abcd",
            ]),
            expected: #"{"nonce":"n","template_hashes":{"line\u2028paragraph\u2029":"abcd"},"timestamp":"t"}"#
        ),
        StatusCanonicalVector(
            name: "lowercase-compatibility",
            input: StatusCanonicalInput(nonce: "n", timestamp: "t", templateHashes: [
                "chatml": "c", "gemma": "d",
            ], modelHashes: ["qwen": "a", "trinity": "b"]),
            expected: #"{"model_hashes":{"qwen":"a","trinity":"b"},"nonce":"n","template_hashes":{"chatml":"c","gemma":"d"},"timestamp":"t"}"#
        ),
        StatusCanonicalVector(
            name: "empty-fields-and-false",
            input: StatusCanonicalInput(
                nonce: "n", timestamp: "t", rdmaDisabled: false, sipEnabled: false,
                secureBootEnabled: true, binaryHash: "", activeModelHash: "",
                pythonHash: "", runtimeHash: ""
            ),
            expected: #"{"nonce":"n","rdma_disabled":false,"secure_boot_enabled":true,"sip_enabled":false,"timestamp":"t"}"#
        ),
        StatusCanonicalVector(
            name: "literal-unicode-escape-text",
            input: StatusCanonicalInput(nonce: "n", timestamp: "t", templateHashes: [
                "literal\\u2028\\u2029": "cafe",
            ]),
            expected: #"{"nonce":"n","template_hashes":{"literal\\u2028\\u2029":"cafe"},"timestamp":"t"}"#
        ),
    ]
}

@Test func statusCanonicalMatchesCoordinatorNestedMapVectors() throws {
    for vector in statusCanonicalVectors() {
        let actual = try StatusCanonical.build(vector.input)
        #expect(actual == Data(vector.expected.utf8), "Canonical byte mismatch: \(vector.name)")
    }
}
