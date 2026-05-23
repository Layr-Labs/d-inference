import XCTest
@testable import ProviderCoreFoundation

final class RoleClassificationTests: XCTestCase {

    func testRoleForKnownFilenames() {
        let cases: [(String, String)] = [
            // weights — strict lowercase matching: uppercase variants classify
            // as "other" because the upstream allow-list also rejects them
            // (HF tooling always produces lowercase filenames).
            ("model.safetensors", "weight"),
            ("MODEL.SAFETENSORS", "other"),
            ("model-00001-of-00002.safetensors", "weight"),
            ("weights.npz", "weight"),
            ("pytorch_model.bin", "weight"),
            // index
            ("model.safetensors.index.json", "index"),
            // tokenizer
            ("tokenizer.json", "tokenizer"),
            ("tokenizer_config.json", "tokenizer"),
            ("tokenizer.model", "tokenizer"),
            ("special_tokens_map.json", "tokenizer"),
            ("added_tokens.json", "tokenizer"),
            ("vocab.json", "tokenizer"),
            ("merges.txt", "tokenizer"),
            // config
            ("config.json", "config"),
            ("generation_config.json", "config"),
            ("quantize_config.json", "config"),
            // template
            ("chat_template.jinja", "template"),
            // preprocessor
            ("preprocessor_config.json", "preprocessor"),
            ("processor_config.json", "preprocessor"),
            // other
            ("README.md", "other"),
            ("license.txt", "other"),
            ("unrelated.xyz", "other"),
        ]
        for (name, expected) in cases {
            let got = ModelScanner.roleFor(filename: name)
            XCTAssertEqual(got, expected, "roleFor(\"\(name)\") expected \(expected) but got \(got)")
        }
    }
}
