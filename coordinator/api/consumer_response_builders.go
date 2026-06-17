package api

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
)

// rewriteRawFinishReason corrects a provider-reported "stop" finish_reason to
// "length" on a raw chat.completion object when the authoritative token counts
// show generation consumed the entire max-tokens budget.
func rewriteRawFinishReason(obj map[string]any, usage protocol.UsageInfo, requestedMax int) {
	if !truncatedByMaxTokens(usage, requestedMax) {
		return
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		if choice, ok := rawChoice.(map[string]any); ok {
			if fr, _ := choice["finish_reason"].(string); fr == "stop" {
				choice["finish_reason"] = "length"
			}
		}
	}
}

func normalizeCompleteChatResponse(obj map[string]any, requestedModel string) {
	if requestedModel != "" {
		obj["model"] = requestedModel
	}
	for _, key := range []string{"system_fingerprint"} {
		if v, ok := obj[key]; ok && v == nil {
			delete(obj, key)
		}
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if message, ok := choice["message"].(map[string]any); ok {
			normalizeCompleteMessage(message)
		}
		if delta, ok := choice["delta"].(map[string]any); ok {
			normalizeCompleteMessage(delta)
		}
	}
}

func normalizeCompleteMessage(message map[string]any) {
	var extractedReasoning string
	if content, ok := message["content"]; !ok || content == nil {
		message["content"] = ""
	} else if contentText, ok := content.(string); ok {
		cleaned, reasoning := stripThinkBlocks(contentText)
		message["content"] = cleaned
		extractedReasoning = reasoning
	}

	if rc, ok := message["reasoning_content"]; ok {
		if rcText, ok := rc.(string); ok && rcText != "" {
			mergeReasoningField(message, rcText)
		}
		delete(message, "reasoning_content")
	}
	if reasoning, ok := message["reasoning"]; ok && reasoning == nil {
		delete(message, "reasoning")
	}
	if extractedReasoning != "" {
		mergeReasoningField(message, extractedReasoning)
	}
	for _, key := range []string{"tool_calls", "refusal"} {
		if v, ok := message[key]; ok && v == nil {
			delete(message, key)
		}
	}
}

func mergeReasoningField(message map[string]any, reasoning string) {
	reasoning = strings.TrimSpace(reasoning)
	if reasoning == "" {
		return
	}
	if existing, ok := message["reasoning"].(string); ok && strings.TrimSpace(existing) != "" {
		if existing != reasoning && !strings.Contains(existing, reasoning) {
			message["reasoning"] = existing + "\n\n" + reasoning
		}
		return
	}
	message["reasoning"] = reasoning
}

func stripThinkBlocks(text string) (string, string) {
	matches := thinkBlockPattern.FindAllStringSubmatch(text, -1)
	reasoningParts := make([]string, 0, len(matches)+1)
	found := len(matches) > 0
	for _, match := range matches {
		if len(match) > 1 {
			if part := strings.TrimSpace(match[1]); part != "" {
				reasoningParts = append(reasoningParts, part)
			}
		}
	}
	cleaned := thinkBlockPattern.ReplaceAllString(text, "")
	lower := strings.ToLower(cleaned)
	if idx := strings.Index(lower, "<think>"); idx >= 0 {
		found = true
		if part := strings.TrimSpace(cleaned[idx+len("<think>"):]); part != "" {
			reasoningParts = append(reasoningParts, part)
		}
		cleaned = cleaned[:idx]
	}
	if !found {
		return text, ""
	}
	return strings.TrimSpace(cleaned), strings.Join(reasoningParts, "\n\n")
}

// normalizeSSEChunk fixes fields in SSE chunks to match the OpenAI spec.
// Some backends (e.g. vllm-mlx) emit "content":null instead of "content":"",
// and include "usage":null which strict parsers (ForgeCode, Codex) reject
// because they expect usage to be either absent or a full object.
func normalizeSSEChunk(chunk string) string {
	line := strings.TrimPrefix(chunk, "data: ")
	// Only trigger the expensive JSON parse for fields we actually fix.
	// "finish_reason":null appears on every chunk but we don't touch it,
	// so checking for generic ":null" causes unnecessary JSON round-trips.
	needsNullFix := strings.Contains(line, `"content":null`) ||
		strings.Contains(line, `"tool_calls":null`) ||
		strings.Contains(line, `"usage":null`) ||
		strings.Contains(line, `"reasoning":null`) ||
		strings.Contains(line, `"reasoning_content":null`) ||
		strings.Contains(line, `"refusal":null`) ||
		strings.Contains(line, `"system_fingerprint":null`)
	needsReasoningDedup := strings.Contains(line, `"reasoning_content"`)
	if !needsNullFix && !needsReasoningDedup {
		return chunk
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return chunk
	}

	changed := false

	// Remove top-level null fields (usage, system_fingerprint, etc.)
	// ForgeCode expects usage to be absent or a full object, not null.
	for _, key := range []string{"usage", "system_fingerprint"} {
		if v, ok := raw[key]; ok && string(v) == "null" {
			delete(raw, key)
			changed = true
		}
	}

	// Fix null fields inside choices[].delta
	if choicesRaw, ok := raw["choices"]; ok {
		var choices []map[string]json.RawMessage
		if err := json.Unmarshal(choicesRaw, &choices); err == nil {
			for i, choice := range choices {
				if deltaRaw, ok := choice["delta"]; ok {
					var delta map[string]json.RawMessage
					if err := json.Unmarshal(deltaRaw, &delta); err == nil {
						for _, field := range []string{"content", "reasoning_content", "reasoning", "refusal"} {
							if v, ok := delta[field]; ok && string(v) == "null" {
								delta[field] = json.RawMessage(`""`)
								changed = true
							}
						}
						if v, ok := delta["tool_calls"]; ok && string(v) == "null" {
							delta["tool_calls"] = json.RawMessage(`[]`)
							changed = true
						}
						// Emit BOTH "reasoning" and "reasoning_content" so both
						// AI SDK (reads reasoning_content) and ForgeCode/other
						// clients (reads reasoning) see reasoning tokens.
						if _, hasR := delta["reasoning"]; hasR {
							if _, hasRC := delta["reasoning_content"]; !hasRC {
								// Only reasoning exists — copy to reasoning_content for AI SDK.
								delta["reasoning_content"] = delta["reasoning"]
								changed = true
							}
						} else if rc, hasRC := delta["reasoning_content"]; hasRC {
							// Only reasoning_content exists — add reasoning alias.
							delta["reasoning"] = rc
							changed = true
						}
						if changed {
							choices[i]["delta"], _ = json.Marshal(delta)
						}
					}
				}
			}
			if changed {
				raw["choices"], _ = json.Marshal(choices)
			}
		}
	}

	if !changed {
		return chunk
	}

	out, err := json.Marshal(raw)
	if err != nil {
		return chunk
	}
	return "data: " + string(out)
}

// extractedMessage holds the reconstructed assistant message from SSE chunks,
// including text content, reasoning, and any tool calls.
type extractedMessage struct {
	Content      string           `json:"content"`
	Reasoning    string           `json:"reasoning,omitempty"`
	ToolCalls    []map[string]any `json:"tool_calls,omitempty"`
	FinishReason string           `json:"-"`
}

// extractMessage parses SSE data lines and reconstructs the full assistant
// message from streaming chunks, including content, reasoning, and tool_calls.
func extractMessage(chunks []string) extractedMessage {
	var contentBuilder strings.Builder
	var reasoningBuilder strings.Builder
	finishReason := ""
	// Tool calls are indexed — accumulate argument fragments by index.
	toolCallMap := map[int]map[string]any{}

	for _, chunk := range chunks {
		line := strings.TrimPrefix(chunk, "data: ")
		line = strings.TrimSpace(line)
		if line == "" || line == "[DONE]" {
			continue
		}

		var parsed map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			continue
		}

		choicesRaw, ok := parsed["choices"]
		if !ok {
			continue
		}
		var choices []struct {
			Delta struct {
				Content          string `json:"content"`
				Reasoning        string `json:"reasoning"`
				ReasoningContent string `json:"reasoning_content"`
				ToolCalls        []struct {
					Index    int    `json:"index"`
					ID       string `json:"id,omitempty"`
					Type     string `json:"type,omitempty"`
					Function struct {
						Name      string `json:"name,omitempty"`
						Arguments string `json:"arguments,omitempty"`
					} `json:"function,omitempty"`
				} `json:"tool_calls,omitempty"`
			} `json:"delta"`
			Message struct {
				Content          string `json:"content"`
				Reasoning        string `json:"reasoning"`
				ReasoningContent string `json:"reasoning_content"`
			} `json:"message"`
			FinishReason *string `json:"finish_reason"`
		}
		if err := json.Unmarshal(choicesRaw, &choices); err != nil {
			continue
		}

		for _, c := range choices {
			if c.FinishReason != nil && *c.FinishReason != "" {
				finishReason = *c.FinishReason
			}
			if c.Delta.Content != "" {
				contentBuilder.WriteString(c.Delta.Content)
			} else if c.Message.Content != "" {
				contentBuilder.WriteString(c.Message.Content)
			}
			if c.Delta.Reasoning != "" {
				reasoningBuilder.WriteString(c.Delta.Reasoning)
			} else if c.Delta.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Delta.ReasoningContent)
			} else if c.Message.Reasoning != "" {
				reasoningBuilder.WriteString(c.Message.Reasoning)
			} else if c.Message.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Message.ReasoningContent)
			}
			for _, tc := range c.Delta.ToolCalls {
				existing, ok := toolCallMap[tc.Index]
				if !ok {
					existing = map[string]any{
						"index": tc.Index,
						"function": map[string]any{
							"arguments": "",
						},
					}
					toolCallMap[tc.Index] = existing
				}
				if tc.ID != "" {
					existing["id"] = tc.ID
				}
				if tc.Type != "" {
					existing["type"] = tc.Type
				}
				fn := existing["function"].(map[string]any)
				if tc.Function.Name != "" {
					fn["name"] = tc.Function.Name
				}
				fn["arguments"] = fn["arguments"].(string) + tc.Function.Arguments
			}
		}
	}

	content := contentBuilder.String()
	reasoning := reasoningBuilder.String()
	if cleaned, extractedReasoning := stripThinkBlocks(content); extractedReasoning != "" {
		content = cleaned
		if strings.TrimSpace(reasoning) != "" {
			reasoning += "\n\n" + extractedReasoning
		} else {
			reasoning = extractedReasoning
		}
	}
	msg := extractedMessage{Content: content, Reasoning: reasoning, FinishReason: finishReason}
	if len(toolCallMap) > 0 {
		msg.ToolCalls = make([]map[string]any, 0, len(toolCallMap))
		for i := range len(toolCallMap) {
			if tc, ok := toolCallMap[i]; ok {
				delete(tc, "index")
				msg.ToolCalls = append(msg.ToolCalls, tc)
			}
		}
	}
	return msg
}

// resolveReasoningTokens returns the reasoning-token count to report.
// It prefers the provider's tokenizer-accurate count
// (UsageInfo.ReasoningTokens) and falls back to the coarse "all
// completion tokens" estimate only for older providers that emit
// reasoning content without a count — so a reasoning response never
// reports zero reasoning tokens, while up-to-date providers report the
// real split.
// injectReasoningDetailIntoRawUsage splices
// completion_tokens_details.reasoning_tokens into a passthrough
// chat.completion object when the provider reported an accurate
// reasoning-token count (UsageInfo.ReasoningTokens) and the raw usage
// object didn't already carry the detail. It never overrides a value the
// provider already supplied, and is a no-op when there is no reasoning
// count or no usage object.
func injectReasoningDetailIntoRawUsage(obj map[string]any, usage protocol.UsageInfo) {
	if usage.ReasoningTokens <= 0 {
		return
	}
	usageObj, ok := obj["usage"].(map[string]any)
	if !ok {
		return
	}
	details, _ := usageObj["completion_tokens_details"].(map[string]any)
	if details == nil {
		details = map[string]any{}
	}
	if _, exists := details["reasoning_tokens"]; exists {
		return
	}
	details["reasoning_tokens"] = usage.ReasoningTokens
	usageObj["completion_tokens_details"] = details
	obj["usage"] = usageObj
}

// parseUsageOnlyStreamChunk decodes a terminal include_usage chunk (empty choices
// + a non-null usage object, carrying the final usage and no content delta) and
// returns the parsed object. ok is false for any other chunk. Parsing here once
// lets the caller hold the object and finalize it at stream end without re-parsing.
// isSSEDoneChunk reports whether a provider stream chunk is the SSE
// "data: [DONE]" terminator (with or without the data: prefix). The
// coordinator owns stream termination — provider terminators are swallowed
// so coordinator-appended events (held usage, SE signature) never trail a
// [DONE] that SDKs treat as final.
func isSSEDoneChunk(chunk string) bool {
	line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(chunk), "data:"))
	return line == "[DONE]"
}

// isResponsesAPIEventChunk reports whether a streamed chunk is a Responses API
// SSE event (its parsed top-level "type" is a "response.*" event). It parses
// rather than substring-matches: a chat.completion content delta whose text
// quotes "response.created"/"response.output_text.delta" (e.g. a user asking
// about the Responses API) must NOT be misread as a Responses stream, which
// would make the relay skip chat-completions termination handling (usage
// splicing, [DONE] swallowing, normalizeSSEChunk) and corrupt the stream.
func isResponsesAPIEventChunk(chunk string) bool {
	line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(chunk), "data:"))
	// Cheap gate: every Responses event names a response.* type at top level.
	if !strings.Contains(line, `"response.`) {
		return false
	}
	var ev struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(line), &ev); err != nil {
		return false
	}
	return strings.HasPrefix(ev.Type, "response.")
}

// isBoilerplateChunk reports whether a streamed provider chunk carries no
// consumer-visible output yet: the preamble emitted BEFORE the failure-prone
// work (media decode, template render, vision prefill) begins. The dispatch
// loop holds such chunks instead of committing on them, so a provider that
// dies after its preamble is retried invisibly instead of surfacing an
// in-band SSE error with zero retries.
//
// Boilerplate is exactly:
//   - a chat.completion.chunk whose choices[].delta carries ONLY the assistant
//     role — content/reasoning/refusal absent, null, or "" (some backends ride
//     an empty content along with the role), tool_calls absent/null/empty,
//     finish_reason null, no usage object; or
//   - a Responses API response.created / response.in_progress lifecycle event
//     (the parsed top-level "type" equals exactly one of those — NOT a mere
//     substring match: a chat content delta whose text quotes "response.created"
//     must still commit).
//
// Everything else — content or tool_call deltas, finish chunks, usage-only
// chunks, [DONE], complete responses, unparseable data — commits the dispatch.
func isBoilerplateChunk(chunk string) bool {
	line := strings.TrimPrefix(strings.TrimPrefix(chunk, "data: "), "data:")
	line = strings.TrimSpace(line)
	// Responses API lifecycle preamble: classify ONLY when the parsed top-level
	// "type" is exactly response.created / response.in_progress. A chat content
	// delta that merely mentions that text (e.g. a user asking about the
	// Responses API) parses as a chat.completion.chunk and falls through to the
	// role-only logic below — it is NOT boilerplate.
	if strings.Contains(line, `"response.created"`) || strings.Contains(line, `"response.in_progress"`) {
		var ev struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal([]byte(line), &ev); err == nil {
			if ev.Type == "response.created" || ev.Type == "response.in_progress" {
				return true
			}
		}
	}
	// Cheap gate: the role preamble always names the role; chunks that can't
	// be it (content deltas, finish chunks, [DONE], garbage) skip the parse.
	if !strings.Contains(line, `"role"`) {
		return false
	}
	var parsed struct {
		Object  string          `json:"object"`
		Usage   json.RawMessage `json:"usage"`
		Choices []struct {
			Delta        map[string]json.RawMessage `json:"delta"`
			FinishReason *string                    `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return false
	}
	if parsed.Object != "chat.completion.chunk" {
		return false
	}
	if len(parsed.Usage) > 0 && string(parsed.Usage) != "null" {
		return false
	}
	if len(parsed.Choices) == 0 {
		return false
	}
	for _, choice := range parsed.Choices {
		if choice.FinishReason != nil {
			return false
		}
		if _, hasRole := choice.Delta["role"]; !hasRole {
			return false
		}
		for field, v := range choice.Delta {
			switch field {
			case "role":
				// The preamble itself.
			case "content", "reasoning_content", "reasoning", "refusal":
				if s := string(v); s != `""` && s != "null" {
					return false
				}
			case "tool_calls":
				if s := string(v); s != "null" && s != "[]" {
					return false
				}
			default:
				// Unknown delta payload — assume it's real output.
				return false
			}
		}
	}
	return true
}

func parseUsageOnlyStreamChunk(chunk string) (obj map[string]any, ok bool) {
	line := strings.TrimPrefix(chunk, "data: ")
	// Cheap gate: skip the parse for content deltas and usage:null chunks.
	if !strings.Contains(line, `"usage"`) || strings.Contains(line, `"usage":null`) {
		return nil, false
	}
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return nil, false
	}
	if u, uok := obj["usage"].(map[string]any); !uok || u == nil {
		return nil, false
	}
	if choices, _ := obj["choices"].([]any); len(choices) != 0 {
		return nil, false
	}
	return obj, true
}

// finalizeUsageChunk renders the held terminal usage chunk for chat-completions
// streaming: it splices the provider's authoritative reasoning count into
// completion_tokens_details (no-op when there is none), strips a null
// system_fingerprint, and rewrites the build id to the public alias — marshalling
// ONCE (obj is already parsed). Returns "" if it can't be marshalled.
func finalizeUsageChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	injectReasoningDetailIntoRawUsage(obj, usage)
	if v, present := obj["system_fingerprint"]; present && v == nil {
		delete(obj, "system_fingerprint")
	}
	if pr.PublicModel != "" && pr.PublicModel != pr.Model {
		obj["model"] = pr.PublicModel
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return "data: " + string(b)
}

// parseFinishStreamChunk decodes a chunk whose choices carry a non-null
// finish_reason (the terminal content chunk). ok is false for any other
// chunk. The parsed object is held by the caller and finalized at stream end
// once the authoritative token counts are known.
func parseFinishStreamChunk(chunk string) (map[string]any, bool) {
	line := strings.TrimPrefix(chunk, "data: ")
	if !strings.Contains(line, `"finish_reason":"`) {
		return nil, false
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return nil, false
	}
	choices, _ := obj["choices"].([]any)
	for _, c := range choices {
		if m, ok := c.(map[string]any); ok {
			if fr, _ := m["finish_reason"].(string); fr != "" {
				return obj, true
			}
		}
	}
	return nil, false
}

// finalizeFinishChunk renders the held terminal finish chunk: when the
// authoritative completion-token count shows generation hit the max-tokens
// bound, a provider-reported "stop" is corrected to "length" (the engine
// doesn't distinguish natural stop from truncation). Also rewrites the build
// id to the public alias. Returns "" if it can't be marshalled.
func finalizeFinishChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	if truncatedByMaxTokens(usage, pr.RequestedMaxTokens) {
		if choices, ok := obj["choices"].([]any); ok {
			for _, c := range choices {
				if m, ok := c.(map[string]any); ok {
					if fr, _ := m["finish_reason"].(string); fr == "stop" {
						m["finish_reason"] = "length"
					}
				}
			}
		}
	}
	if pr.PublicModel != "" && pr.PublicModel != pr.Model {
		obj["model"] = pr.PublicModel
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return "data: " + string(b)
}

// truncatedByMaxTokens reports whether generation consumed the entire
// max-tokens budget. requestedMax is the effective bound — the consumer's
// explicit max_tokens or the coordinator-injected default — so hitting it
// means the engine cut generation short.
func truncatedByMaxTokens(usage protocol.UsageInfo, requestedMax int) bool {
	return requestedMax > 0 && usage.CompletionTokens >= requestedMax
}

// effectiveFinishReason resolves the finish_reason for a reconstructed
// response. The provider engine reports "stop" unconditionally, so a
// truncation-aware reason is re-derived from the authoritative token counts.
func effectiveFinishReason(extracted string, hasToolCalls bool, usage protocol.UsageInfo, requestedMax int) string {
	if extracted != "" && extracted != "stop" {
		return extracted
	}
	if truncatedByMaxTokens(usage, requestedMax) {
		return "length"
	}
	if hasToolCalls {
		return "tool_calls"
	}
	return "stop"
}

func resolveReasoningTokens(usage protocol.UsageInfo, reasoning string) uint64 {
	if usage.ReasoningTokens > 0 {
		return uint64(usage.ReasoningTokens)
	}
	if reasoning != "" {
		return uint64(usage.CompletionTokens)
	}
	return 0
}

func buildResponsesUsage(promptTokens, completionTokens uint64, reasoningTokens uint64) types.ResponsesUsage {
	return types.ResponsesUsage{
		InputTokens:        int(promptTokens),
		InputTokensDetail:  types.ResponsesUsageDetail{},
		OutputTokens:       int(completionTokens),
		OutputTokensDetail: types.ResponsesUsageDetail{ReasoningTokens: int(reasoningTokens)},
	}
}

func buildResponsesIncompleteDetails(finishReason string) *types.ResponsesIncompleteDetail {
	switch finishReason {
	case "length":
		return &types.ResponsesIncompleteDetail{Reason: "max_output_tokens"}
	case "content_filter":
		return &types.ResponsesIncompleteDetail{Reason: "content_filter"}
	default:
		return nil
	}
}

func responseItemID(prefix, requestID string, index int) string {
	return fmt.Sprintf("%s_%s_%d", prefix, strings.ReplaceAll(requestID, "-", ""), index)
}

func appendResponsesOutputItems(output []any, requestID string, msg extractedMessage) []any {
	index := len(output)
	if msg.Reasoning != "" {
		output = append(output, map[string]any{
			"type": "reasoning",
			"id":   responseItemID("rs", requestID, index),
			"summary": []map[string]any{{
				"type": "summary_text",
				"text": msg.Reasoning,
			}},
		})
		index++
	}
	if msg.Content != "" || len(msg.ToolCalls) == 0 {
		output = append(output, map[string]any{
			"type":   "message",
			"role":   "assistant",
			"status": "completed",
			"id":     responseItemID("msg", requestID, index),
			"content": []map[string]any{{
				"type":        "output_text",
				"text":        msg.Content,
				"annotations": []any{},
			}},
		})
		index++
	}
	for _, tc := range msg.ToolCalls {
		fn, _ := tc["function"].(map[string]any)
		callID, _ := tc["id"].(string)
		if callID == "" {
			callID = responseItemID("call", requestID, index)
		}
		name, _ := fn["name"].(string)
		args, _ := fn["arguments"].(string)
		output = append(output, map[string]any{
			"type":      "function_call",
			"id":        responseItemID("fc", requestID, index),
			"call_id":   callID,
			"name":      name,
			"arguments": args,
			"status":    "completed",
		})
		index++
	}
	return output
}

// finalizeResponsesEnvelope fills the spec-required envelope fields of a
// Responses object: status derived from incomplete_details, and the
// always-present defaults (tool_choice, tools, metadata, parallel_tool_calls).
func finalizeResponsesEnvelope(r *types.ResponsesResponse) {
	if r.IncompleteDetail != nil {
		r.Status = "incomplete"
	} else {
		r.Status = "completed"
	}
	r.ParallelToolCalls = true
	if r.ToolChoice == nil {
		r.ToolChoice = "auto"
	}
	if r.Tools == nil {
		r.Tools = []any{}
	}
	if r.Metadata == nil {
		r.Metadata = map[string]any{}
	}
}

func buildResponsesResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string) types.ResponsesResponse {
	reasoningTokens := resolveReasoningTokens(usage, msg.Reasoning)
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)
	resp := types.ResponsesResponse{
		ID:               "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:           "response",
		CreatedAt:        time.Now().Unix(),
		Model:            model,
		Output:           appendResponsesOutputItems(nil, requestID, msg),
		Usage:            buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
		IncompleteDetail: buildResponsesIncompleteDetails(finishReason),
	}
	finalizeResponsesEnvelope(&resp)
	if seSignature != "" {
		resp.SESignature = seSignature
		resp.ResponseHash = responseHash
	}
	return resp
}

func firstChoice(resp types.ChatCompletionResponse) *types.ChatCompletionChoice {
	if len(resp.Choices) == 0 {
		return nil
	}
	return &resp.Choices[0]
}

func chatUsageToResponsesUsage(resp types.ChatCompletionResponse, reasoning string) types.ResponsesUsage {
	reasoningTokens := 0
	if d := resp.Usage.CompletionTokensDetails; d != nil && d.ReasoningTokens > 0 {
		reasoningTokens = d.ReasoningTokens
	} else if reasoning != "" {
		reasoningTokens = resp.Usage.CompletionTokens
	}
	return buildResponsesUsage(uint64(resp.Usage.PromptTokens), uint64(resp.Usage.CompletionTokens), uint64(reasoningTokens))
}

func chatCompletionToResponses(resp types.ChatCompletionResponse, requestedModel, seSignature, responseHash string) types.ResponsesResponse {
	requestID := strings.TrimPrefix(resp.ID, "chatcmpl-")
	if requestID == "" {
		requestID = uuid.NewString()
	}
	created := int(resp.Created)
	if created <= 0 {
		created = int(time.Now().Unix())
	}

	msg := extractedMessage{}
	finishReason := ""
	if choice := firstChoice(resp); choice != nil {
		finishReason = choice.FinishReason
		msg.Content = choice.Message.Content
		msg.Reasoning = choice.Message.Reasoning
		msg.ToolCalls = choice.Message.ToolCalls
	}

	r := types.ResponsesResponse{
		ID:        "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:    "response",
		CreatedAt: int64(created),
		Model:     requestedModel,
		Output:    appendResponsesOutputItems(nil, requestID, msg),
		Usage:     chatUsageToResponsesUsage(resp, msg.Reasoning),
	}
	if finishReason != "" && finishReason != "stop" {
		r.IncompleteDetail = buildResponsesIncompleteDetails(finishReason)
	}
	finalizeResponsesEnvelope(&r)
	if seSignature != "" {
		r.SESignature = seSignature
		r.ResponseHash = responseHash
	}
	return r
}

func buildNonStreamingResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string) types.ChatCompletionResponse {
	message := types.ChatCompletionMessage{
		Role:    "assistant",
		Content: msg.Content,
	}
	if msg.Reasoning != "" {
		message.Reasoning = msg.Reasoning
	}

	if len(msg.ToolCalls) > 0 {
		message.ToolCalls = msg.ToolCalls
	}
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)

	resp := types.ChatCompletionResponse{
		ID:      "chatcmpl-" + requestID,
		Object:  "chat.completion",
		Created: time.Now().Unix(),
		Model:   model,
		Choices: []types.ChatCompletionChoice{{
			Index:        0,
			Message:      message,
			FinishReason: finishReason,
		}},
		Usage: types.ChatCompletionUsage{
			PromptTokens:     usage.PromptTokens,
			CompletionTokens: usage.CompletionTokens,
			TotalTokens:      usage.PromptTokens + usage.CompletionTokens,
		},
	}

	// Surface the OpenAI-standard reasoning-token breakdown when present
	// so non-streaming chat-completions consumers can read it (the
	// streaming path carries it on the provider's verbatim usage chunk).
	if rt := resolveReasoningTokens(usage, msg.Reasoning); rt > 0 {
		resp.Usage.CompletionTokensDetails = &types.CompletionTokensDetails{
			ReasoningTokens: int(rt),
		}
	}

	if seSignature != "" {
		resp.SESignature = seSignature
		resp.ResponseHash = responseHash
	}

	return resp
}
