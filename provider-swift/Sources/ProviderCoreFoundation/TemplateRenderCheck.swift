// Copyright © 2026 Eigen Labs.
//
// Scan-time template-render self-check.
//
// Background (DAR-130): Gemma's `chat_template.jinja` applies `| upper` to
// tool-schema `type` fields; legitimate request shapes the template didn't
// anticipate crashed the Jinja render at request time and surfaced to
// consumers as 500s. Binary-side normalization (`ToolSchemaNormalization`)
// fixed that specific shape, but the failure CLASS — a registry-published
// chat template that throws on legitimate request shapes — will recur with
// future model publishes.
//
// This check runs at model-scan time: it renders every chat template the
// snapshot ships against canonical fixtures that mirror exactly what the
// runtime hands the template — post-normalization tool schemas (every node
// has a string `type`, nullability as `nullable: true`), runtime message
// dictionaries (`MLXBatchedEngineServerEngine+Translation.templateMessage()`
// shapes for tool calls/responses, `MessageGenerator` content-parts shapes
// for multimodal) — using the same Jinja engine and compile options the
// runtime tokenizer uses (swift-jinja via swift-transformers, with
// `lstripBlocks`/`trimBlocks` enabled). The result is advertised per model
// as `template_render_ok` so the coordinator can refuse to route
// tool-bearing requests to a (provider, model) whose template is broken.

import Foundation
import Jinja

public enum TemplateRenderCheck {

    // MARK: - Template discovery

    /// Collect every chat-template STRING the runtime could use from a model
    /// snapshot directory, in the runtime's precedence order
    /// (swift-transformers `Hub.swift`): `chat_template.jinja` (plain text),
    /// then `chat_template.json` (`chat_template` key), then
    /// `tokenizer_config.json` (`chat_template` key — string form, or the
    /// list-of-`{name, template}` form, all entries collected).
    ///
    /// All sources present in the snapshot are collected (not just the
    /// winning one): the runtime's selection can change across paths
    /// (named-template lookup, `tool_use` template selection), so a broken
    /// template anywhere in the snapshot is a latent request-time crash.
    public static func templateSources(at snapshotDir: URL) -> [String] {
        var sources: [String] = []

        // 1. chat_template.jinja — plain-text Jinja file.
        let jinjaURL = snapshotDir.appendingPathComponent("chat_template.jinja")
        if let text = try? String(contentsOf: jinjaURL, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sources.append(text)
        }

        // 2. chat_template.json — {"chat_template": <string | [{name, template}]>}.
        sources.append(contentsOf: chatTemplateValues(
            fromJSONFile: snapshotDir.appendingPathComponent("chat_template.json")))

        // 3. tokenizer_config.json — same `chat_template` key shapes.
        sources.append(contentsOf: chatTemplateValues(
            fromJSONFile: snapshotDir.appendingPathComponent("tokenizer_config.json")))

        return sources
    }

    /// Extract template strings from a JSON file's `chat_template` key.
    /// Handles the string form and the list-of-`{name, template}` form
    /// (all list entries are collected). Returns [] when the file is
    /// missing, unparseable, or carries no usable template.
    private static func chatTemplateValues(fromJSONFile url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let value = json["chat_template"]
        else { return [] }

        if let template = value as? String {
            return template.isEmpty ? [] : [template]
        }
        if let entries = value as? [Any] {
            return entries.compactMap { entry in
                guard let dict = entry as? [String: Any],
                    let template = dict["template"] as? String,
                    !template.isEmpty
                else { return nil }
                return template
            }
        }
        return []
    }

    // MARK: - Render check

    /// Render every template the snapshot ships against every canonical
    /// fixture.
    ///
    /// - Returns: `nil` when the snapshot has no chat template (unknown —
    ///   the key is omitted on the wire, matching old providers); `false`
    ///   when any template fails to compile or any fixture render throws
    ///   (the routing signal); `true` when everything renders.
    ///
    /// Never throws and never traps: this runs inside the startup model
    /// scan for every cached model, so any unexpected condition degrades to
    /// a result, not a crash. Multimodal (content-parts) fixtures are only
    /// rendered for vision models (`config.json` declares `vision_config`),
    /// mirroring the runtime: `MessageGenerator`s only emit content-parts
    /// message shapes for VLM models, so judging a text-only template
    /// against parts it will never see would false-flag healthy models.
    public static func renderOK(at snapshotDir: URL) -> Bool? {
        let sources = templateSources(at: snapshotDir)
        guard !sources.isEmpty else { return nil }

        let includeMultimodal = configDeclaresVision(at: snapshotDir)
        let fixtures = canonicalFixtures(includeMultimodal: includeMultimodal)
        let specialTokens = specialTokenContext(at: snapshotDir)

        for source in sources {
            // Same compile options as the runtime tokenizer
            // (swift-transformers `compiledTemplate(for:)`).
            let template: Template
            do {
                template = try Template(source, with: .init(lstripBlocks: true, trimBlocks: true))
            } catch {
                // A template that doesn't compile can't render at request time.
                return false
            }
            for fixture in fixtures {
                do {
                    let context = try renderContext(for: fixture, specialTokens: specialTokens)
                    _ = try template.render(context)
                } catch {
                    return false
                }
            }
        }
        return true
    }

    /// Whether `config.json` declares a vision tower (`vision_config`).
    /// Mirrors `ModelScanner.configDeclaresVision` / `ProviderLoop.modelIsVLM`,
    /// re-derived here so the Linux-buildable foundation target stays
    /// dependency-free.
    static func configDeclaresVision(at snapshotDir: URL) -> Bool {
        let configURL = snapshotDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return json["vision_config"] != nil
    }

    // MARK: - Render context

    /// Special-token attributes the runtime tokenizer injects into the
    /// render context (swift-transformers `specialTokenAttributes`, minus
    /// `additional_special_tokens` which no chat template interpolates).
    private static let specialTokenAttributes: [String] = [
        "bos_token", "eos_token", "unk_token", "sep_token",
        "pad_token", "cls_token", "mask_token",
    ]

    /// Build the special-token slice of the render context. `bos_token` and
    /// `eos_token` default to "" (so a bare `chat_template.jinja` with no
    /// tokenizer_config still renders — real templates open with
    /// `{{ bos_token }}`); every attribute present in tokenizer_config.json
    /// overrides, accepting both the plain-string and the added-token
    /// (`{"content": "..."}`) forms, mirroring the runtime's
    /// `addedTokenAsString` handling.
    static func specialTokenContext(at snapshotDir: URL) -> [String: Value] {
        var tokens: [String: Value] = [
            "bos_token": .string(""),
            "eos_token": .string(""),
        ]
        let configURL = snapshotDir.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return tokens }

        for attribute in specialTokenAttributes {
            guard let value = json[attribute] else { continue }
            if let string = value as? String {
                tokens[attribute] = .string(string)
            } else if let dict = value as? [String: Any],
                let content = dict["content"] as? String {
                tokens[attribute] = .string(content)
            }
        }
        return tokens
    }

    /// Assemble the full Jinja render context for one fixture: `messages`,
    /// `add_generation_prompt` (always true — the runtime entrypoint
    /// `applyChatTemplate(messages:tools:additionalContext:)` always
    /// generates), `tools` only when the fixture carries them (mirrors the
    /// runtime, which only sets the context key for tool-bearing requests),
    /// plus the special-token attributes.
    private static func renderContext(
        for fixture: Fixture,
        specialTokens: [String: Value]
    ) throws -> [String: Value] {
        var context: [String: Value] = specialTokens
        // Strip Harmony assistant replay tags, then JSON `null` / `Optional`
        // leaves, exactly as the
        // runtime tokenize chokepoints now do (`sanitizeJinjaMessages` /
        // `ChatTemplateFixes.sanitizeTools`) before `Value(any:)`. Without this the
        // channel-tagged and null-bearing fixtures below would throw here and
        // false-flag every healthy template; with it the self-check stays
        // faithful to "renders here == renders at request time".
        context["messages"] = .array(
            try fixture.messages.map { message in
                try Value(any: sanitizeForJinja(stripHarmonyFraming(message)))
            })
        context["add_generation_prompt"] = .boolean(true)
        if let tools = fixture.tools {
            context["tools"] = .array(
                try tools.map { try Value(any: sanitizeForJinja($0)) })
        }
        return context
    }

    /// Apply Harmony replay normalization in the self-check's `[String: Any]`
    /// fixture domain. The shared string sanitizer remains the source of truth;
    /// this wrapper only handles role/key selection for message dictionaries.
    private static func stripHarmonyFraming(_ message: [String: Any]) -> [String: Any] {
        guard (message["role"] as? String) == "assistant" else { return message }

        var output = message
        for key in ["content", "thinking", "reasoning_content"] {
            if let text = output[key] as? String {
                output[key] = stripHarmonyChannelFraming(fromAssistantContent: text)
            }
        }
        return output
    }

    // MARK: - Canonical fixtures

    /// A canonical request shape: messages exactly as the runtime's
    /// template layer sees them, plus tools when the fixture exercises the
    /// tool branches.
    struct Fixture {
        let name: String
        let messages: [[String: Any]]
        let tools: [[String: Any]]?

        init(name: String, messages: [[String: Any]], tools: [[String: Any]]? = nil) {
            self.name = name
            self.messages = messages
            self.tools = tools
        }
    }

    /// The canonical fixture set. Multimodal (content-parts) fixtures are
    /// included only for vision models — see `renderOK(at:)`.
    static func canonicalFixtures(includeMultimodal: Bool) -> [Fixture] {
        var fixtures: [Fixture] = [
            plainChatFixture,
            assistantChannelTagsFixture,
            toolFlowFixture,
            toolFlowWithNullsFixture,
            emptyAssistantTailFixture,
        ]
        if includeMultimodal {
            fixtures.append(imagePartsFixture)
            fixtures.append(videoPartsFixture)
        }
        return fixtures
    }

    /// (a) Plain system + user chat — the baseline every template must render.
    static var plainChatFixture: Fixture {
        Fixture(
            name: "plain_chat",
            messages: [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": "Write one sentence about the sea."],
            ]
        )
    }

    /// (a′) Prior assistant turn replayed with raw Harmony channel framing.
    /// Harmony drops prior-turn analysis at inference and replays only the
    /// final answer, so the self-check must normalize this shape before render.
    static var assistantChannelTagsFixture: Fixture {
        Fixture(
            name: "assistant_channel_tags",
            messages: [
                ["role": "user", "content": "What's the weather?"],
                [
                    "role": "assistant",
                    "content": "<|channel|>analysis<|message|>The user wants the weather.<|end|><|channel|>final<|message|>It is sunny.",
                ],
                ["role": "user", "content": "What should I wear?"],
            ]
        )
    }

    /// (b) User content as PARTS — image variant. Mirrors the
    /// `MessageGenerator` shape (`[{"type":"image"},{"type":"text",...}]`)
    /// that VLM models receive (e.g. `Gemma4MessageGenerator`).
    static var imagePartsFixture: Fixture {
        Fixture(
            name: "image_parts",
            messages: [
                [
                    "role": "user",
                    "content": [
                        ["type": "image"],
                        ["type": "text", "text": "Describe this image."],
                    ] as [[String: Any]],
                ]
            ]
        )
    }

    /// (b) User content as PARTS — video variant.
    static var videoPartsFixture: Fixture {
        Fixture(
            name: "video_parts",
            messages: [
                [
                    "role": "user",
                    "content": [
                        ["type": "video"],
                        ["type": "text", "text": "Describe this video."],
                    ] as [[String: Any]],
                ]
            ]
        )
    }

    /// (c) Full tool flow in POST-NORMALIZATION shape (the runtime
    /// normalizes inbound schemas since 0.6.3 — `ToolSchemaNormalization` —
    /// so every schema node HAS a string `type` and nullability is
    /// `nullable: true`). One tool with nested object params including an
    /// enum property, array items, and required lists; an assistant turn
    /// with `tool_calls` (arguments as a dict — mirrors
    /// `decodeToolCallArguments`) followed by a `role: "tool"` response
    /// message, exercising the declaration, call, and response template
    /// branches.
    static var toolFlowFixture: Fixture {
        Fixture(
            name: "tool_flow",
            messages: [
                ["role": "user", "content": "What's the weather in Paris?"],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call_0001",
                            "type": "function",
                            "function": [
                                "name": "get_weather",
                                "arguments": [
                                    "location": "Paris, France",
                                    "unit": "celsius",
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any]
                    ] as [[String: Any]],
                ],
                [
                    "role": "tool",
                    "content": "{\"temperature\": 21, \"condition\": \"sunny\"}",
                    "tool_call_id": "call_0001",
                    "name": "get_weather",
                ],
            ],
            tools: [Self.canonicalTool]
        )
    }

    /// (c′) A tool flow carrying literal JSON `null` leaves — the
    /// shapes that crashed `Jinja.Value(any:)` at request time before the
    /// sanitizer landed. The assistant tool call's decoded `arguments`
    /// carries a `null` value (`unit`); the tool's `parameters` schema
    /// carries a `null` enum element and a `"default": null`. `NSNull()` is
    /// the literal JSON-null sentinel `JSONSerialization` yields, matching
    /// what `decodeToolCallArguments` hands the runtime. After
    /// sanitization these null leaves are dropped, so this fixture renders
    /// on every healthy template (`renderOK == true`) instead of throwing.
    static var toolFlowWithNullsFixture: Fixture {
        Fixture(
            name: "tool_flow_with_nulls",
            messages: [
                ["role": "user", "content": "What's the weather in SF?"],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        [
                            "id": "call_0002",
                            "type": "function",
                            "function": [
                                "name": "get_weather",
                                "arguments": [
                                    "city": "SF",
                                    "unit": NSNull(),
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any]
                    ] as [[String: Any]],
                ],
                [
                    "role": "tool",
                    "content": "{\"temperature\": 19, \"condition\": \"foggy\"}",
                    "tool_call_id": "call_0002",
                    "name": "get_weather",
                ],
            ],
            tools: [Self.canonicalToolWithNulls]
        )
    }

    /// (d) `add_generation_prompt` with an empty assistant tail — exercises
    /// last-message indexing and empty-content trims.
    static var emptyAssistantTailFixture: Fixture {
        Fixture(
            name: "empty_assistant_tail",
            messages: [
                ["role": "user", "content": "Continue from here."],
                ["role": "assistant", "content": ""],
            ]
        )
    }

    /// The canonical post-normalization tool: nested object params with an
    /// enum property, array items, a nullable property, and required lists
    /// at both levels. Every schema node carries a string `type` —
    /// `ToolSchemaNormalization.ensureParameterTypes` guarantees this for
    /// real inbound requests, so this is exactly what templates see.
    static var canonicalTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get the current weather and short-term forecast for a location.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "location": [
                            "type": "string",
                            "description": "City and country, e.g. Paris, France",
                        ],
                        "unit": [
                            "type": "string",
                            "enum": ["celsius", "fahrenheit"],
                            "description": "Temperature unit",
                        ],
                        "days": [
                            "type": "array",
                            "items": ["type": "integer"] as [String: Any],
                            "description": "Number of forecast days to include",
                        ],
                        "options": [
                            "type": "object",
                            "properties": [
                                "verbose": [
                                    "type": "boolean",
                                    "description": "Include extended fields",
                                ],
                                "retries": [
                                    "type": "integer",
                                    "nullable": true,
                                    "description": "Optional retry budget",
                                ] as [String: Any],
                            ] as [String: Any],
                            "required": ["verbose"],
                            "description": "Advanced lookup options",
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["location", "unit"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// Variant of `canonicalTool` carrying literal JSON `null`
    /// leaves inside the `function.parameters` schema: a `"default": null`
    /// on a property and a `null` element inside an `enum`. `NSNull()` is
    /// the literal JSON-null sentinel. Every node still carries a string
    /// `type` (the post-normalization invariant). After sanitization the
    /// null leaves are dropped, leaving a schema every healthy template
    /// renders — the schema-side half of the bug class the self-check must
    /// now exercise.
    static var canonicalToolWithNulls: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get the current weather for a location.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "city": [
                            "type": "string",
                            "description": "City name",
                            // Literal JSON `null` default — dropped by the
                            // sanitizer; crashes `Value(any:)` unsanitized.
                            "default": NSNull(),
                        ] as [String: Any],
                        "unit": [
                            "type": "string",
                            // Literal `null` enum element — dropped by the
                            // sanitizer, leaving the two real options.
                            "enum": ["celsius", "fahrenheit", NSNull()] as [Any],
                            "description": "Temperature unit",
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["city"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
}
