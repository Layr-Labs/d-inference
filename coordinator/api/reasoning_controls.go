package api

// Reasoning on/off controls (OpenRouter #612 baseline: "reasoning disabled
// but the endpoint still returns reasoning output").
//
// Providers decode exactly ONE reasoning switch from the sealed body:
// `reasoning: {"enabled": <bool>}` — the Swift engine maps it to the
// `enable_thinking` chat-template variable (Qwen3.6/Qwen3-style templates
// pre-close the think block when it is false). But the OpenAI/OpenRouter
// surface accepts several equivalent spellings of "reasoning off", and any
// spelling the coordinator forwards un-normalized is silently ignored by the
// template — a hybrid-thinking model such as Qwen3.6 then thinks by DEFAULT
// and the consumer receives reasoning it explicitly disabled:
//
//   - reasoning: {"enabled": false}      (canonical — already honored)
//   - reasoning: {"effort": "none"}      (OpenRouter's OpenAI-style disable)
//   - reasoning_effort: "none"           (top-level OpenAI-style shorthand)
//   - thinking: {"type": "disabled"}     (Anthropic /v1/messages)
//
// normalizeReasoningControls canonicalizes all of them into the one shape
// providers decode, BEFORE the body is sealed — so the entire deployed fleet
// honors the disable without a provider release. It also reports whether
// reasoning text must be suppressed from the consumer-facing response:
//
//   - reasoning: {"exclude": true}       (generate internally, never return)
//   - include_reasoning: false           (deprecated alias of exclude:true)
//   - any disable spelling               (belt-and-braces: a model can still
//     open its own <think> block despite a disabled-thinking prompt; the
//     consumer asked for zero reasoning, so zero reasoning is returned)
//
// Suppression strips reasoning TEXT only. Usage token accounting
// (completion_tokens_details.reasoning_tokens) is deliberately untouched:
// generated reasoning tokens are billed whether or not they are returned.

import (
	"encoding/json"
	"strings"
)

// normalizeReasoningControls rewrites every documented "reasoning off"
// spelling in a parsed request body into the canonical provider shape
// `reasoning: {"enabled": false}`. It returns mutated=true when the body
// changed (callers must re-marshal the forward body), and suppress=true when
// reasoning text must not appear in the consumer-facing response.
//
// Precedence: an explicit `reasoning.enabled` boolean always wins over the
// effort/thinking-derived spellings, matching OpenRouter's documented
// semantics ("enabled: inferred from effort" — an explicit value is never
// re-inferred).
func normalizeReasoningControls(parsed map[string]any) (mutated, suppress bool) {
	reasoning, _ := parsed["reasoning"].(map[string]any)

	explicitEnabled, hasExplicit := false, false
	if reasoning != nil {
		if enabled, ok := reasoning["enabled"].(bool); ok {
			explicitEnabled, hasExplicit = enabled, true
		}
		if exclude, ok := reasoning["exclude"].(bool); ok && exclude {
			suppress = true
		}
	}
	if include, ok := parsed["include_reasoning"].(bool); ok && !include {
		suppress = true
	}

	disabled := hasExplicit && !explicitEnabled

	// A concrete (non-"none") effort inside the reasoning object takes
	// precedence over the legacy top-level shorthand per OpenRouter's
	// parameter hierarchy, so a contradictory top-level "none" must not
	// disable. Read before the deletes below can drop the key.
	objectEffort, hasObjectEffort := reasoning["effort"].(string)
	objectHasConcreteEffort := hasObjectEffort && !isNoneEffort(objectEffort)

	// reasoning.effort: "none" — OpenRouter's OpenAI-style disable. The value
	// is removed either way: no chat template accepts "none" as an effort
	// level, and the canonical enabled=false below carries the semantics.
	if hasObjectEffort && isNoneEffort(objectEffort) {
		if !hasExplicit {
			disabled = true
		}
		delete(reasoning, "effort")
		mutated = true
	}
	// Top-level reasoning_effort: "none" — the OpenAI shorthand. Removed so
	// no template ever renders a literal "none" effort (gpt-oss renders the
	// field verbatim into its system header).
	if effort, ok := parsed["reasoning_effort"].(string); ok && isNoneEffort(effort) {
		if !hasExplicit && !objectHasConcreteEffort {
			disabled = true
		}
		delete(parsed, "reasoning_effort")
		mutated = true
	}
	// Anthropic thinking config (/v1/messages): {"type": "disabled"} turns
	// extended thinking off; {"type": "enabled"} turns it on. The endpoint
	// lowering clones unknown fields verbatim, so mapping here covers the
	// lowered provider body too.
	if thinking, ok := parsed["thinking"].(map[string]any); ok && !hasExplicit {
		switch kind, _ := thinking["type"].(string); kind {
		case "disabled":
			disabled = true
		case "enabled":
			if setReasoningEnabled(parsed, reasoning, true) {
				mutated = true
			}
		}
	}

	if disabled {
		suppress = true
		if setReasoningEnabled(parsed, reasoning, false) {
			mutated = true
		}
	}
	return mutated, suppress
}

// setReasoningEnabled writes the canonical `reasoning.enabled` value into the
// body, creating the reasoning object when absent. Returns true when the body
// actually changed.
func setReasoningEnabled(parsed map[string]any, reasoning map[string]any, enabled bool) bool {
	if reasoning == nil {
		parsed["reasoning"] = map[string]any{"enabled": enabled}
		return true
	}
	if current, ok := reasoning["enabled"].(bool); ok && current == enabled {
		return false
	}
	reasoning["enabled"] = enabled
	return true
}

// isNoneEffort reports whether a reasoning-effort string spells the
// OpenRouter/OpenAI "disable reasoning entirely" level.
func isNoneEffort(effort string) bool {
	return strings.EqualFold(strings.TrimSpace(effort), "none")
}

// reasoningDeltaFields are the assistant-delta keys that carry reasoning TEXT
// on the chat-completions wire (the coordinator emits both spellings — see
// normalizeSSEChunk).
var reasoningDeltaFields = []string{"reasoning", "reasoning_content"}

// stripReasoningFromStreamChunk removes reasoning text fields from a
// chat.completion.chunk SSE line. It returns the rewritten chunk and
// drop=true when the chunk carried ONLY reasoning deltas — nothing a
// suppressed-reasoning consumer needs — so the caller skips it entirely
// (forwarding an empty {"delta":{}} frame for every hidden reasoning token
// would leak the reasoning cadence and confuse strict SDK parsers).
//
// Chunks carrying anything else (role preamble, content, tool calls,
// refusal, finish_reason, usage) are kept with just the reasoning fields
// deleted. Non-chunk lines and unparsable payloads pass through untouched.
func stripReasoningFromStreamChunk(chunk string) (string, bool) {
	line := strings.TrimSpace(chunk)
	if !strings.HasPrefix(line, "data: ") {
		return chunk, false
	}
	payload := strings.TrimPrefix(line, "data: ")
	// Cheap pre-filter: only pay for the JSON round-trip when a reasoning
	// field can actually be present.
	if !strings.Contains(payload, `"reasoning`) {
		return chunk, false
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(payload), &raw); err != nil {
		return chunk, false
	}
	choicesRaw, ok := raw["choices"]
	if !ok {
		return chunk, false
	}
	var choices []map[string]json.RawMessage
	if err := json.Unmarshal(choicesRaw, &choices); err != nil {
		return chunk, false
	}

	changed := false
	reasoningOnly := len(choices) > 0
	for i, choice := range choices {
		if fr, ok := choice["finish_reason"]; ok && string(fr) != "null" {
			reasoningOnly = false
		}
		// Some backends emit message-shaped choices mid-stream; those carry
		// a full assistant message and are never dropped, only stripped.
		if messageRaw, ok := choice["message"]; ok {
			reasoningOnly = false
			var message map[string]json.RawMessage
			if err := json.Unmarshal(messageRaw, &message); err == nil {
				for _, field := range reasoningDeltaFields {
					if _, ok := message[field]; ok {
						delete(message, field)
						changed = true
					}
				}
				choices[i]["message"], _ = json.Marshal(message)
			}
		}
		deltaRaw, ok := choice["delta"]
		if !ok {
			reasoningOnly = false
			continue
		}
		var delta map[string]json.RawMessage
		if err := json.Unmarshal(deltaRaw, &delta); err != nil {
			reasoningOnly = false
			continue
		}
		for _, field := range reasoningDeltaFields {
			if _, ok := delta[field]; ok {
				delete(delta, field)
				changed = true
			}
		}
		if len(delta) > 0 {
			reasoningOnly = false
		}
		choices[i]["delta"], _ = json.Marshal(delta)
	}
	if !changed {
		return chunk, false
	}
	// A usage-bearing chunk is terminal accounting — never dropped.
	if usage, ok := raw["usage"]; ok && string(usage) != "null" {
		reasoningOnly = false
	}
	if reasoningOnly {
		return "", true
	}
	raw["choices"], _ = json.Marshal(choices)
	fixed, err := json.Marshal(raw)
	if err != nil {
		return chunk, false
	}
	return "data: " + string(fixed), false
}

// stripReasoningFromCompleteResponse removes reasoning text fields from a raw
// chat.completion object's choices (both the message and delta shapes some
// backends emit). Usage accounting is untouched.
func stripReasoningFromCompleteResponse(obj map[string]any) {
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		for _, key := range []string{"message", "delta"} {
			if member, ok := choice[key].(map[string]any); ok {
				for _, field := range reasoningDeltaFields {
					delete(member, field)
				}
			}
		}
	}
}
