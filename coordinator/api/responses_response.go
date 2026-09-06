package api

import (
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
)

func buildResponsesUsage(promptTokens, completionTokens, reasoningTokens, cachedTokens uint64) types.ResponsesUsage {
	return types.ResponsesUsage{
		InputTokens:        int(promptTokens),
		InputTokensDetail:  types.ResponsesUsageDetail{CachedTokens: int(cachedTokens)},
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
func finalizeResponsesEnvelope(
	r *types.ResponsesResponse,
	traits registry.RequestTraits,
) {
	if r.IncompleteDetail != nil {
		r.Status = "incomplete"
	} else {
		r.Status = "completed"
	}
	r.ToolChoice, r.ParallelToolCalls = responsesToolPolicy(traits)
	if r.Tools == nil {
		r.Tools = []any{}
	}
	if r.Metadata == nil {
		r.Metadata = map[string]any{}
	}
}

func buildResponsesResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string, policies ...registry.RequestTraits) types.ResponsesResponse {
	reasoningTokens := resolveReasoningTokens(usage, msg.Reasoning)
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)
	resp := types.ResponsesResponse{
		ID:               "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:           "response",
		CreatedAt:        time.Now().Unix(),
		Model:            model,
		Output:           appendResponsesOutputItems(nil, requestID, msg),
		Usage:            buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens, uint64(usage.CachedTokens)),
		IncompleteDetail: buildResponsesIncompleteDetails(finishReason),
	}
	var traits registry.RequestTraits
	if len(policies) > 0 {
		traits = policies[0]
	}
	finalizeResponsesEnvelope(&resp, traits)
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
	cachedTokens := 0
	if details := resp.Usage.PromptTokensDetails; details != nil {
		cachedTokens = details.CachedTokens
	}
	return buildResponsesUsage(uint64(resp.Usage.PromptTokens), uint64(resp.Usage.CompletionTokens), uint64(reasoningTokens), uint64(cachedTokens))
}

func chatCompletionToResponses(resp types.ChatCompletionResponse, requestedModel, seSignature, responseHash string, policies ...registry.RequestTraits) types.ResponsesResponse {
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
	var traits registry.RequestTraits
	if len(policies) > 0 {
		traits = policies[0]
	}
	finalizeResponsesEnvelope(&r, traits)
	if seSignature != "" {
		r.SESignature = seSignature
		r.ResponseHash = responseHash
	}
	return r
}
