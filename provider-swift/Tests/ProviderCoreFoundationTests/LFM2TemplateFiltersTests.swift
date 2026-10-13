// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import Testing
@testable import ProviderCoreFoundation

/// Synthetic LFM2.5-shaped template features (no official template text):
/// pythonic argument replay via `string`, tool schemas via `tojson`, and the
/// Hugging Face `{% generation %}` block.
struct LFM2TemplateFiltersTests {
    private static let source = """
        {%- macro arg(v) -%}{%- if v is string -%}{{ "'" + v + "'" }}{%- elif v is mapping or v is iterable -%}\
        {{ v | tojson }}{%- else -%}{{ v | string }}{%- endif -%}{%- endmacro -%}
        {%- for m in messages -%}{%- generation -%}[{%- for k, v in m.args.items() -%}{{ k }}={{ arg(v) }}\
        {%- if not loop.last %}, {% endif -%}{%- endfor -%}]{%- endgeneration -%}{%- endfor -%}
        |{{ tools | tojson }}
        """

    private func render(modelType: String) throws -> String {
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: modelType)
        let template = try Template(
            NemotronTemplateFilters.bindingFilters(in: Self.source, modelType: modelType),
            with: .init(lstripBlocks: true, trimBlocks: true))
        let context: [String: Value] = [
            "messages": .array([.object([
                "args": .object([
                    "a_flag": .boolean(true), "b_off": .boolean(false), "c_n": .int(2),
                    "d_x": .double(0.75), "e_s": .string("é"), "f_list": .array([.int(1), .int(2)]),
                    "g_obj": .object(["k": .string("v")]),
                ]),
            ])]),
            "tools": .array([.object(["name": .string("get_time — ISO"), "strict": .boolean(true)])]),
        ]
        return try template.render(context, environment: environment)
    }

    @Test func lfm2UsesTransformersStringAndJSONSpellings() throws {
        #expect(try render(modelType: "lfm2_moe") == """
            [a_flag=True, b_off=False, c_n=2, d_x=0.75, e_s='é', f_list=[1, 2], g_obj={"k": "v"}]\
            |[{"name": "get_time — ISO", "strict": true}]
            """)
    }

    /// Regression: before LFM was admitted, swift-jinja's Foundation defaults
    /// rendered `true` and compact ASCII-escaped JSON, diverging from the
    /// reference prompt the model was trained on.
    @Test func unadmittedFamiliesKeepSwiftJinjaDefaults() throws {
        #expect(try render(modelType: "lfm2") == """
            [a_flag=true, b_off=false, c_n=2, d_x=0.75, e_s='é', f_list=[1,2], g_obj={"k":"v"}]\
            |[{"name":"get_time \\u2014 ISO","strict":true}]
            """)
    }

    @Test func gatesAreModelScoped() {
        #expect(NemotronTemplateFilters.usesReferenceFilters(modelType: " LFM2_MOE "))
        #expect(NemotronTemplateFilters.usesReferenceFilters(modelType: "nemotron_h"))
        #expect(!NemotronTemplateFilters.usesReferenceFilters(modelType: "lfm2"))
        #expect(!NemotronTemplateFilters.usesReferenceFilters(modelType: "qwen3_5"))
        #expect(!NemotronTemplateFilters.usesReferenceFilters(modelType: nil))
        // Nemotron-only request policy (tool `strict` retention) is unchanged.
        #expect(!NemotronTemplateFilters.applies(modelType: "lfm2_moe"))
        #expect(NemotronTemplateFilters.additionalContext(modelType: "lfm2_moe") != nil)
    }
}
