import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

extension GemmaToolConstraintTests {
    @Test("finite strings cannot contain Gemma parser delimiters")
    func parserDelimiterFailsClosed() throws {
        for marker in [
            #"<|"|>"#, "<escape>", "<|tool_call>", "<tool_call|>",
            "<start_function_call>", "<end_function_call>",
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        "const": .string("bad\(marker)value"),
                    ]),
                ]),
                "required": .array([.string("value")]),
            ])
            let request = request(
                choice: .mode(.required),
                tools: [tool(parameters: parameters)])
            let prepared = try ToolChoicePromptPolicy.prepare(request)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                _ = try ToolConstraintFactory.make(
                    prepared: prepared,
                    request: request,
                    tokenizer: tokenizer,
                    modelContext: .init(
                        modelId: request.model, modelType: "gemma4_text"),
                    defaultMaxTokens: 128,
                    stopTokenIDs: [128])
            }
        }
    }

    @Test("auto admits finite decimal enums and enforces them post-generation")
    func autoFiniteDecimalsAreAdmitted() throws {
        let body = """
            {
              "model":"gemma-4-test",
              "messages":[{"role":"user","content":"x"}],
              "tools":[{"type":"function","function":{
                "name":"calculate",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "value":{"type":"number","enum":[0.10000000000000001]}
                  }
                }
              }}],
              "tool_choice":"auto"
            }
            """
        let decoded = try JSONDecoder().decode(
            OpenAIChatCompletionRequest.self,
            from: Data(body.utf8))
        // `auto` compiles no grammar, so exact-render feasibility is
        // irrelevant: the decimal enum survives to the post-generation
        // validator, which compares JSON numbers mathematically.
        let prepared = try ToolChoicePromptPolicy.prepare(decoded)
        #expect(prepared.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "calculate",
                arguments: ["value": .double(0.10000000000000001)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "calculate", arguments: ["value": .double(0.5)])),
            ], prepared: prepared)
        }
    }

    @Test("parallel policy and schema validator reject invalid auto output")
    func outputValidation() throws {
        let baseRequest = request(choice: .mode(.auto), parallel: false)
        let prepared = try ToolChoicePromptPolicy.prepare(baseRequest)
        let valid = ToolCall(function: .init(
            name: "weather", arguments: ["city": .string("Paris")]))
        try ToolConstraintValidation.validate([valid], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([valid, valid], prepared: prepared)
        }
        let invalid = ToolCall(function: .init(
            name: "weather", arguments: ["city": .int(1)]))
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([invalid], prepared: prepared)
        }

        let broadSchema: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "patternProperties": .object([
                "^city$": .object([
                    "oneOf": .array([
                        .object([
                            "type": .string("string"),
                            "const": .string("Paris"),
                        ]),
                        .object([
                            "type": .string("string"),
                            "const": .string("Tokyo"),
                        ]),
                    ]),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
        let broadRequest = request(
            choice: .mode(.auto),
            tools: [tool(parameters: broadSchema)],
            parallel: false)
        let broadPrepared = try ToolChoicePromptPolicy.prepare(broadRequest)
        #expect(broadPrepared.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["city": .string("Paris")])),
        ], prepared: broadPrepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["country": .string("FR")])),
            ], prepared: broadPrepared)
        }

        // An unevaluatable regex must not reject. `auto` no longer pre-screens
        // schemas, so `patternProperties` the validator cannot decide goes
        // unenforced — and the `additionalProperties: false` fallback goes with
        // it, because the property might have matched the undecided pattern.
        let unsafePatternSchema: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "patternProperties": .object([
                "^(a+)+$": .object(["type": .string("string")]),
            ]),
            "additionalProperties": .bool(false),
        ])
        let unsafePrepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: unsafePatternSchema)],
                parallel: false))
        #expect(unsafePrepared.compiledTools == nil)
        for name in ["aaa", "zzz"] {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: [name: .string("ok")])),
            ], prepared: unsafePrepared)
        }
    }

    @Test("auto does not assert a regex the validator cannot evaluate")
    func unevaluatableAutoRegexIsNotAsserted() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "code": .object([
                    "type": .string("string"),
                    "pattern": .string("^[a-z]+$"),
                    "minLength": .int(2),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        // The literal-pattern subset cannot decide a character class, and an
        // undecided assertion is NOT asserted — never a failure.
        for value in ["abc", "ABC-123"] {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["code": .string(value)])),
            ], prepared: prepared)
        }
        // Decidable assertions on the same node still bite.
        for invalid: MLXLMCommon.JSONValue in [.string("a"), .int(7)] {
            #expect(
                throws: MultiModelBatchSchedulerEngineError.self, "\(invalid)"
            ) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["code": invalid])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto admits every standard JSON-Schema construct unchanged")
    func standardAutoSchemasPrepareSuccessfully() throws {
        let schemas: [MLXLMCommon.JSONValue] = [
            .object([
                "type": .array([.string("string"), .string("integer")]),
            ]),
            .object([
                "oneOf": .array([
                    .object(["type": .string("string")]),
                    .object(["type": .string("integer")]),
                ]),
            ]),
            .object([
                "$ref": .string("#/$defs/Address"),
            ]),
            .object([
                "$dynamicRef": .string("#address"),
            ]),
            .object([
                "$recursiveRef": .string("#"),
            ]),
            .object([
                "if": .object([
                    "properties": .object([
                        "kind": .object(["const": .string("business")]),
                    ]),
                ]),
                "then": .object([
                    "required": .array([.string("tax_id")]),
                ]),
            ]),
            .object([
                "dependentRequired": .object([
                    "credit_card": .array([.string("billing_address")]),
                ]),
            ]),
            .object([
                "dependencies": .object([
                    "credit_card": .array([.string("billing_address")]),
                ]),
            ]),
            .object([
                "type": .string("object"),
                "unevaluatedProperties": .bool(false),
            ]),
            .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "unevaluatedItems": .bool(false),
            ]),
            .object([
                "enum": .array([.string("a"), .int(1)]),
            ]),
            .object([
                "minimum": .int(5),
                "minLength": .int(2),
            ]),
            .object([
                "not": .object(["type": .string("string")]),
            ]),
        ]
        for schema in schemas {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object(["value": schema]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            // `auto` has no grammar, so the schema must reach the
            // post-generation validator byte-for-byte.
            #expect(
                prepared.tools?.first?.function.parameters == parameters,
                "\(schema)")
            #expect(prepared.compiledTools == nil, "\(schema)")
        }
    }

    @Test("auto validates multi-type anyOf branches post-generation")
    func autoMultiTypeAnyOfValidatesEitherBranch() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "anyOf": .array([
                        .object([
                            "type": .string("string"), "minLength": .int(2),
                        ]),
                        .object([
                            "type": .string("integer"), "minimum": .int(10),
                        ]),
                    ]),
                    // Sibling render type pins the REAL wire shape: the
                    // normalizer injects the FIRST branch's type so templates
                    // can subscript `value['type']`.
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        for value: MLXLMCommon.JSONValue in [.string("ok"), .int(11)] {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": value])),
            ], prepared: prepared)
        }
        for value: MLXLMCommon.JSONValue in [.string("x"), .int(9), .bool(true)] {
            #expect(
                throws: MultiModelBatchSchedulerEngineError.self, "\(value)"
            ) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": value])),
                ], prepared: prepared)
            }
        }
        // `required` still compiles a real grammar and still fails closed on
        // the multi-type union.
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("auto: $ref suppresses only the injected type, not author siblings")
    func autoRefBearingNodeEnforcesAuthorSiblings() throws {
        // The normalizer stamps `type: "string"` on $ref-only nodes so
        // templates can subscript the render type; the validator cannot
        // resolve the reference, so that injected type must not veto an
        // emission the REFERENCED schema accepts. Author-written siblings
        // are conjunctive with the reference (draft 2019-09+) and stay
        // enforced — a $ref beside a const must not disable the const.
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "p": .object([
                    "$ref": .string("#/$defs/P"),
                    "type": .string("string"),
                ]),
                "mode": .object([
                    "$ref": .string("#/$defs/M"),
                    "enum": .array([.string("fast"), .string("safe")]),
                    "type": .string("string"),
                ]),
            ]),
            "$defs": .object([
                "P": .object(["type": .string("object")]),
                "M": .object(["type": .string("string")]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        // Injected type suppressed: an object emission for `p` passes.
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "p": .object(["street": .string("Main")]),
                    "mode": .string("fast"),
                ])),
        ], prepared: prepared)
        // Author enum beside the $ref still bites.
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: [
                        "p": .string("ok"),
                        "mode": .string("reckless"),
                    ])),
            ], prepared: prepared)
        }
    }

    @Test("injected union render type does not veto non-first branches")
    func autoInjectedUnionRenderTypeDoesNotVetoBranches() throws {
        // The normalized wire shape: the sibling `type` is the render type
        // injected from the FIRST union branch.
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "anyOf": .array([
                        .object(["type": .string("string")]),
                        .object([
                            "type": .string("integer"), "minimum": .int(10),
                        ]),
                    ]),
                    "type": .string("string"),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        for value: MLXLMCommon.JSONValue in [.string("ok"), .int(11)] {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": value])),
            ], prepared: prepared)
        }
        // Branch assertions still bite: no branch admits 9 or a bool.
        for value: MLXLMCommon.JSONValue in [.int(9), .bool(true)] {
            #expect(
                throws: MultiModelBatchSchedulerEngineError.self, "\(value)"
            ) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": value])),
                ], prepared: prepared)
            }
        }
    }

    @Test("normalized mixed-type enum accepts every member")
    func autoNormalizedMixedEnumAcceptsEveryMember() throws {
        // A typeless {"enum":["a",1]} gets render type "string" injected
        // from its first member; finite-value identity subsumes typing.
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "enum": .array([.string("a"), .int(1)]),
                    "type": .string("string"),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        for value: MLXLMCommon.JSONValue in [.string("a"), .int(1)] {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": value])),
            ], prepared: prepared)
        }
        for value: MLXLMCommon.JSONValue in [.int(2), .string("b")] {
            #expect(
                throws: MultiModelBatchSchedulerEngineError.self, "\(value)"
            ) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": value])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto enforces if/then/else")
    func autoIfThenElseIsEnforced() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "credit_card": .object(["type": .string("string")]),
                "billing_address": .object(["type": .string("string")]),
            ]),
            "if": .object(["required": .array([.string("credit_card")])]),
            "then": .object([
                "required": .array([.string("billing_address")]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["credit_card": .string("4111")])),
            ], prepared: prepared)
        }
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "credit_card": .string("4111"),
                    "billing_address": .string("1 Main St"),
                ])),
        ], prepared: prepared)
        try ToolConstraintValidation.validate([
            .init(function: .init(name: "weather", arguments: [:])),
        ], prepared: prepared)

        let withElse: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "card": .object(["type": .string("string")]),
                "cash": .object(["type": .string("string")]),
            ]),
            "if": .object(["required": .array([.string("card")])]),
            "else": .object(["required": .array([.string("cash")])]),
        ])
        let preparedElse = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: withElse)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["card": .string("visa")])),
        ], prepared: preparedElse)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["cash": .string("20")])),
        ], prepared: preparedElse)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(name: "weather", arguments: [:])),
            ], prepared: preparedElse)
        }
    }

    @Test("auto enforces dependentRequired")
    func autoDependentRequiredIsEnforced() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "credit_card": .object(["type": .string("string")]),
                "billing_address": .object(["type": .string("string")]),
            ]),
            "dependentRequired": .object([
                "credit_card": .array([.string("billing_address")]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["credit_card": .string("4111")])),
            ], prepared: prepared)
        }
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "credit_card": .string("4111"),
                    "billing_address": .string("1 Main St"),
                ])),
        ], prepared: prepared)
        try ToolConstraintValidation.validate([
            .init(function: .init(name: "weather", arguments: [:])),
        ], prepared: prepared)
    }

    @Test("auto propertyNames enforces literal-safe assertions on keys")
    func autoPropertyNamesMaxLengthRejectsLongKey() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "propertyNames": .object(["maxLength": .int(3)]),
            "additionalProperties": .bool(true),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["abc": .int(1)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["toolong": .int(1)])),
            ], prepared: prepared)
        }
    }

    @Test("allOf does not suppress the sibling type assertion")
    func autoAllOfDoesNotSuppressSiblingType() throws {
        // allOf branches are conjunctive, so a render type derived from
        // branch one is implied by the conjunction; no exemption applies.
        for branch: MLXLMCommon.JSONValue in [
            .object(["type": .string("string")]),
            .object(["minimum": .int(0)]),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "allOf": .array([branch]),
                        "type": .string("string"),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": .string("ok")])),
            ], prepared: prepared)
            #expect(
                throws: MultiModelBatchSchedulerEngineError.self, "\(branch)"
            ) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": .int(5)])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto enforces dependentSchemas while required stays fail-closed")
    func dependentSchemasAreEnforcedUnderAuto() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "credit_card": .object(["type": .string("string")]),
                "billing_address": .object(["type": .string("string")]),
            ]),
            "dependentSchemas": .object([
                "credit_card": .object([
                    "required": .array([.string("billing_address")]),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["credit_card": .string("4111")])),
            ], prepared: prepared)
        }
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "credit_card": .string("4111"),
                    "billing_address": .string("1 Main St"),
                ])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("auto enforces propertyNames while required stays fail-closed")
    func propertyNamesIsEnforcedUnderAuto() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "propertyNames": .object([
                "const": .string("allowed"),
            ]),
            "additionalProperties": .bool(true),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["allowed": .int(1)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["anything": .int(1)])),
            ], prepared: prepared)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("direct requests reject reserved boolean schema metadata")
    func directRequestRejectsReservedBooleanMetadata() {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    ToolSchemaNormalization.originalBooleanSchemaKey: .bool(true),
                ]),
            ]),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]),
                allowInternalSchemaMetadata: false)
        }
        #expect(throws: Never.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]),
                allowInternalSchemaMetadata: true)
        }
    }

    @Test("auto pattern validation distinguishes keywords from property names")
    func autoPatternPropertyNameIsNotAKeyword() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "pattern": .string("^city$"),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["pattern": .string("city")])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["pattern": .string("other")])),
            ], prepared: prepared)
        }
    }

    @Test("reserved-metadata walk fails closed beyond its depth bound")
    func reservedMetadataWalkFailsClosedBeyondBound() throws {
        // Within the bound, nesting depth alone is not forgery.
        var shallow: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
            "pattern": .string("^city$"),
        ])
        for _ in 0 ..< 20 {
            shallow = .array([shallow])
        }
        _ = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: .object([
                    "type": .string("array"),
                    "items": shallow,
                ]))]),
            allowInternalSchemaMetadata: false)

        // Beyond the bound the guard rejects rather than vouching for
        // content it never scanned: the normalizer's marker-folding walk is
        // depth-unbounded, so a forged marker below the guard's horizon
        // would otherwise fold upward into vouched shallow metadata.
        var forged: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
            ToolSchemaNormalization.originalBooleanSchemaKey: .bool(true),
        ])
        for _ in 0 ..< 40 {
            forged = .array([forged])
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: .object([
                        "type": .string("array"),
                        "items": forged,
                    ]))]),
                allowInternalSchemaMetadata: false)
        }

        // A marker inside the bound is still forgery.
        var nested: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
            ToolSchemaNormalization.originalBooleanSchemaKey: .bool(true),
        ])
        for _ in 0 ..< 4 {
            nested = .object([
                "type": .string("array"),
                "items": nested,
            ])
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: .object([
                        "type": .string("object"),
                        "properties": .object(["value": nested]),
                    ]))]),
                allowInternalSchemaMetadata: false)
        }
    }

    @Test("auto validation honors draft-04 tuple items and additionalItems")
    func autoTupleItemsValidation() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "coordinates": .object([
                    "type": .string("array"),
                    "items": .array([
                        .object(["type": .string("integer")]),
                        .object(["type": .string("string")]),
                    ]),
                    "additionalItems": .bool(false),
                ]),
            ]),
            "required": .array([.string("coordinates")]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "coordinates": .array([.int(7), .string("north")]),
                ])),
        ], prepared: prepared)
        for invalid in [
            MLXLMCommon.JSONValue.array([.string("north"), .int(7)]),
            .array([.int(7), .string("north"), .bool(true)]),
        ] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather",
                        arguments: ["coordinates": invalid])),
                ], prepared: prepared)
            }
        }
    }

    @Test("empty draft-04 tuples preserve additionalItems semantics")
    func autoEmptyTupleItemsValidation() throws {
        for (additionalItems, shouldPass) in [
            (MLXLMCommon.JSONValue?.none, true),
            (.some(.bool(false)), false),
        ] {
            var coordinateSchema: [String: MLXLMCommon.JSONValue] = [
                "type": .string("array"),
                "items": .array([]),
            ]
            coordinateSchema["additionalItems"] = additionalItems
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "coordinates": .object(coordinateSchema),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            let call = ToolCall(function: .init(
                name: "weather",
                arguments: ["coordinates": .array([.int(7)])]))
            if shouldPass {
                try ToolConstraintValidation.validate([call], prepared: prepared)
            } else {
                #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                    try ToolConstraintValidation.validate([call], prepared: prepared)
                }
            }
        }
    }

    @Test("auto integer validation accepts only integral finite doubles")
    func autoIntegerValidationAcceptsIntegralDoubles() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "count": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("count")]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["count": .double(1.0)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["count": .double(1.5)])),
            ], prepared: prepared)
        }
    }

    @Test("auto enum and const compare JSON numbers mathematically")
    func autoNumericFiniteValuesCompareAcrossRepresentations() throws {
        for assertion in [
            ("enum", MLXLMCommon.JSONValue.array([.int(1)])),
            ("const", MLXLMCommon.JSONValue.int(1)),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("number"),
                        assertion.0: assertion.1,
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            #expect(prepared.compiledTools == nil)
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": .double(1.0)])),
            ], prepared: prepared)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": .double(2.0)])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto uniqueItems uses JSON Schema numeric equality")
    func autoUniqueItemsUsesSchemaEquality() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "values": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("number")]),
                    "uniqueItems": .bool(true),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["values": .array([.int(1), .double(2.0)])])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["values": .array([.int(1), .double(1.0)])])),
            ], prepared: prepared)
        }
    }

    @Test("JSON Schema string identity uses Unicode scalar sequences")
    func autoStringIdentityUsesUnicodeScalars() throws {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        let enumParameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "enum": .array([.string(precomposed)]),
                    "minLength": .int(0),
                ]),
            ]),
        ])
        let enumPrepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: enumParameters)]))
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .string(decomposed)])),
            ], prepared: enumPrepared)
        }

        let uniqueParameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "values": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "uniqueItems": .bool(true),
                ]),
            ]),
        ])
        let uniquePrepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: uniqueParameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "values": .array([.string(precomposed), .string(decomposed)]),
                ])),
        ], prepared: uniquePrepared)
    }

    @Test("auto array contains and match bounds are enforced")
    func autoArrayContainsValidation() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "values": .object([
                    "type": .string("array"),
                    "contains": .object(["const": .int(1)]),
                    "minContains": .int(1),
                    "maxContains": .int(1),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["values": .array([.int(1), .int(2)])])),
        ], prepared: prepared)
        for invalid in [
            MLXLMCommon.JSONValue.array([.int(2)]),
            .array([.int(1), .int(1)]),
        ] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["values": invalid])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto numeric bounds preserve integer precision")
    func autoNumericBoundsPreserveIntegerPrecision() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("integer"),
                    "maximum": .int(9_007_199_254_740_992),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["value": .int(9_007_199_254_740_992)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .int(9_007_199_254_740_993)])),
            ], prepared: prepared)
        }
        for (value, multiple) in [
            (Int.max, 3e-20),
            (9_007_199_254_740_992, 3e-40),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("integer"),
                        "multipleOf": .double(multiple),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather",
                        arguments: ["value": .int(value)])),
                ], prepared: prepared)
            }
        }
        for multiple in [0.1, 1e-200] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("integer"),
                        "multipleOf": .double(multiple),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .int(1)])),
            ], prepared: prepared)
        }
    }

    @Test("auto integer multipleOf preserves precision")
    func autoIntegerMultipleOfPreservesPrecision() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("integer"),
                    "multipleOf": .int(2),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["value": .int(9_007_199_254_740_992)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .int(9_007_199_254_740_993)])),
            ], prepared: prepared)
        }
    }

    @Test("auto decimal multipleOf preserves large integer precision")
    func autoDecimalMultipleOfPreservesLargeIntegerPrecision() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("integer"),
                    "multipleOf": .double(2.5),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["value": .int(9_007_199_254_740_990)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .int(9_007_199_254_740_993)])),
            ], prepared: prepared)
        }
    }

    @Test("floating multipleOf uses exact decoded JSON decimals")
    func floatingMultipleOfUsesExactJSONDecimals() throws {
        let cases: [
            (
                multiple: MLXLMCommon.JSONValue,
                valid: MLXLMCommon.JSONValue,
                invalid: MLXLMCommon.JSONValue
            )
        ] = [
            (.int(1), .double(1), .double(1.0000000001)),
            (.double(0.1), .double(0.3), .double(0.30000000000000004)),
            (.double(1e-200), .double(1e-199), .double(1.0000000001e-199)),
            (.double(3e-40), .double(9e-40), .double(9.000000001e-40)),
            (.double(1e200), .double(1e200), .double(1.0000000000000001e200)),
        ]

        for testCase in cases {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("number"),
                        "multipleOf": testCase.multiple,
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))

            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": testCase.valid])),
            ], prepared: prepared)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather",
                        arguments: ["value": testCase.invalid])),
                ], prepared: prepared)
            }
        }
    }

    @Test("compiled integer enum preserves integral-double precision")
    func compiledIntegerEnumPreservesPrecision() throws {
        let allowed = 9_007_199_254_740_993
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("integer"),
                    "enum": .array([.int(allowed)]),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools != nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["value": .int(allowed)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .double(9_007_199_254_740_992.0)])),
            ], prepared: prepared)
        }
    }

    @Test("auto numeric bounds support the full finite Double range")
    func autoNumericBoundsSupportFullDoubleRange() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("number"),
                    "minimum": .double(1e199),
                    "maximum": .double(1e201),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["value": .double(1e200)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .double(1e202)])),
            ], prepared: prepared)
        }
    }

    @Test("auto validation honors draft-04 boolean exclusive bounds")
    func autoDraft04ExclusiveBounds() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("number"),
                    "minimum": .int(5),
                    "exclusiveMinimum": .bool(true),
                    "maximum": .int(10),
                    "exclusiveMaximum": .bool(true),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["value": .int(6)])),
        ], prepared: prepared)
        for boundary in [5, 10] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": .int(boundary)])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto string bounds count Unicode code points")
    func autoStringBoundsUseUnicodeCodePoints() throws {
        let decomposed = "e\u{301}"
        for (assertion, bound, shouldPass) in [
            ("minLength", 2, true),
            ("maxLength", 1, false),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        assertion: .int(bound),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            let call = ToolCall(function: .init(
                name: "weather", arguments: ["value": .string(decomposed)]))
            if shouldPass {
                try ToolConstraintValidation.validate([call], prepared: prepared)
            } else {
                #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                    try ToolConstraintValidation.validate([call], prepared: prepared)
                }
            }
        }
    }

    @Test("auto validation restores normalized boolean schema semantics")
    func autoBooleanSchemaSemanticsSurviveNormalization() throws {
        for accepts in [true, false] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        ToolSchemaNormalization.originalBooleanSchemaKey:
                            .bool(accepts),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            #expect(prepared.compiledTools == nil)
            let call = ToolCall(function: .init(
                name: "weather", arguments: ["value": .int(7)]))
            if accepts {
                try ToolConstraintValidation.validate([call], prepared: prepared)
            } else {
                #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                    try ToolConstraintValidation.validate([call], prepared: prepared)
                }
            }
        }
    }

    @Test("typeless finite schemas keep original semantics through normalization")
    func typelessFiniteSchemasSurviveNormalization() throws {
        let body = Data(
            """
            {"model":"gemma-4-test",
             "messages":[{"role":"user","content":"pick"}],
             "tools":[{"type":"function","function":{"name":"pick","parameters":{
               "type":"object",
               "properties":{
                 "count":{"const":1},
                 "level":{"enum":[1,2,null]},
                 "tag":{"enum":["a","b"]},
                 "score":{"minimum":5,"maximum":10}
               }}}}],
             "tool_choice":"auto"}
            """.utf8)
        let decoded = try ProviderLoop.decodeOpenAIRequest(body)
        let normalized = try #require(
            decoded.tools?.first?.function.parameters)
        guard case .object(let root) = normalized,
            case .object(let properties)? = root["properties"],
            case .object(let count)? = properties["count"],
            case .object(let level)? = properties["level"],
            case .object(let tag)? = properties["tag"],
            case .object(let score)? = properties["score"]
        else {
            Issue.record("normalized parameters lost their shape")
            return
        }
        #expect(count["type"] == .string("number"))
        #expect(level["type"] == .string("number"))
        #expect(level["nullable"] == .bool(true))
        #expect(tag["type"] == .string("string"))
        #expect(score["type"] == .string("number"))

        let prepared = try ToolChoicePromptPolicy.prepare(decoded)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "pick",
                arguments: [
                    "count": .int(1), "level": .null, "tag": .string("a"),
                    "score": .int(6),
                ])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "pick", arguments: ["count": .int(2)])),
            ], prepared: prepared)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "pick", arguments: ["score": .int(4)])),
            ], prepared: prepared)
        }
    }

    @Test("empty schemas keep allow-all semantics through normalization")
    func emptySchemasKeepAllowAllSemantics() throws {
        let body = Data(
            """
            {"model":"gemma-4-test",
             "messages":[{"role":"user","content":"pick"}],
             "tools":[{"type":"function","function":{"name":"pick","parameters":{
               "type":"object",
               "properties":{
                 "blob":{},
                 "nested":{"allOf":[{}],"description":"anything"}
               }}}}],
             "tool_choice":"auto"}
            """.utf8)
        let decoded = try ProviderLoop.decodeOpenAIRequest(body)
        let prepared = try ToolChoicePromptPolicy.prepare(decoded)
        // The render-only string rewrite must not become an authoritative
        // compiled grammar: auto falls back to raw allow-all validation.
        #expect(prepared.compiledTools == nil)
        for value: MLXLMCommon.JSONValue in [
            .int(7), .object(["k": .string("v")]), .string("text"), .null,
        ] {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "pick",
                    arguments: ["blob": value, "nested": value])),
            ], prepared: prepared)
        }

        // Direct (un-normalized) `{}` behaves identically.
        let direct = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["blob": .object([:])]),
                ]))]))
        #expect(direct.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["blob": .int(7)])),
        ], prepared: direct)

        // Grammar modes keep compiling the marker rewrite as the free string
        // the original `{}` compiled to before the marker existed.
        let requiredBody = Data(
            """
            {"model":"gemma-4-test",
             "messages":[{"role":"user","content":"pick"}],
             "tools":[{"type":"function","function":{"name":"pick","parameters":{
               "type":"object",
               "properties":{"blob":{}}}}}],
             "tool_choice":"required"}
            """.utf8)
        let requiredPrepared = try ToolChoicePromptPolicy.prepare(
            try ProviderLoop.decodeOpenAIRequest(requiredBody))
        #expect(requiredPrepared.compiledTools != nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "pick", arguments: ["blob": .string("text")])),
        ], prepared: requiredPrepared)
    }

    @Test("property names compare by Unicode scalar sequence")
    func propertyNamesUseUnicodeScalars() throws {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                precomposed: .object(["type": .string("string")]),
            ]),
            "required": .array([.string(precomposed)]),
            "additionalProperties": .bool(false),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [precomposed: .string("ok")])),
        ], prepared: prepared)
        // A decomposed key is a DIFFERENT JSON property name: it neither
        // satisfies `required` nor escapes additionalProperties:false.
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: [decomposed: .string("ok")])),
            ], prepared: prepared)
        }
    }

    @Test("pattern literals compare by Unicode scalar sequence")
    func patternLiteralsUseUnicodeScalars() throws {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        for (pattern, value, shouldPass) in [
            ("^\(precomposed)$", precomposed, true),
            ("^\(precomposed)$", decomposed, false),
            ("^\(precomposed)", "\(decomposed)tail", false),
            ("\(precomposed)$", "head\(decomposed)", false),
            (precomposed, "a\(decomposed)b", false),
            (precomposed, "a\(precomposed)b", true),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        "pattern": .string(pattern),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            let call = ToolCall(function: .init(
                name: "weather", arguments: ["value": .string(value)]))
            if shouldPass {
                try ToolConstraintValidation.validate([call], prepared: prepared)
            } else {
                #expect(
                    throws: MultiModelBatchSchedulerEngineError.self,
                    "pattern \(pattern) vs \(value)"
                ) {
                    try ToolConstraintValidation.validate([call], prepared: prepared)
                }
            }
        }
    }

    @Test("count bounds accept integral finite doubles")
    func countBoundsAcceptIntegralDoubles() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "minLength": .double(1.0),
                ]),
                "list": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")]),
                    "maxItems": .double(2.0),
                    "contains": .object(["const": .int(1)]),
                    "minContains": .double(1.0),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "name": .string("a"),
                    "list": .array([.int(1), .int(2)]),
                ])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["name": .string("")])),
            ], prepared: prepared)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["list": .array([.int(1), .int(2), .int(3)])])),
            ], prepared: prepared)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["list": .array([.int(2)])])),
            ], prepared: prepared)
        }
    }

    @Test("constrained array bounds accept integral finite doubles")
    func constrainedArrayBoundsAcceptIntegralDoubles() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "values": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "minItems": .double(1.0),
                    "maxItems": .double(2.0),
                ]),
            ]),
        ])
        _ = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.required),
                tools: [tool(parameters: parameters)]))

        var fractional = parameters
        if case .object(var root) = fractional,
            case .object(var properties)? = root["properties"],
            case .object(var values)? = properties["values"]
        {
            values["maxItems"] = .double(1.5)
            properties["values"] = .object(values)
            root["properties"] = .object(properties)
            fractional = .object(root)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: fractional)]))
        }
    }

    @Test("nullable enum grammars admit null only when the enum contains null")
    func nullableEnumWithoutNullRejectsNull() throws {
        let withoutNull: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "enum": .array([.string("ok")]),
                ]),
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
        ])
        let enumRequest = request(
            choice: .mode(.required), tools: [tool(parameters: withoutNull)])
        let prepared = try ToolChoicePromptPolicy.prepare(enumRequest)
        #expect(prepared.compiledTools != nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["value": .string("ok")])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": .null])),
            ], prepared: prepared)
        }

        // The compiled automaton must not open a null branch at the value
        // position: after `value:` only the enum's `<|"|>` opener is legal.
        let constraint = try #require(try ToolConstraintFactory.make(
            prepared: prepared,
            request: enumRequest,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: enumRequest.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128]))
        var state = constraint.initialState
        for token in "<|tool_call>call:weather{value:".utf8.map(Int.init) {
            state = try #require(
                constraint.nextState(state: state, tokenID: token))
        }
        let allowed = constraint.allowedTokenIDs(
            state: state, remainingTokens: 64)
        #expect(!allowed.contains(Int(UInt8(ascii: "n"))))

        let withNull: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .array([.string("string"), .string("null")]),
                    "enum": .array([.string("ok"), .null]),
                ]),
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
        ])
        let nullPrepared = try ToolChoicePromptPolicy.prepare(
            request(choice: .mode(.required), tools: [tool(parameters: withNull)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["value": .null])),
        ], prepared: nullPrepared)
    }
}
