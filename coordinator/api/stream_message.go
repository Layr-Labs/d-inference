package api

import (
	"bytes"
	"encoding/json"
	"log"
	"strings"
)

// extractedMessage holds the reconstructed assistant message from SSE chunks,
// including text content, reasoning, and any tool calls.
type extractedMessage struct {
	Content                 string           `json:"content"`
	Reasoning               string           `json:"reasoning,omitempty"`
	ReasoningDetails        any              `json:"reasoning_details,omitempty"`
	ReasoningDetailsPresent bool             `json:"-"`
	ToolCalls               []map[string]any `json:"tool_calls,omitempty"`
	FinishReason            string           `json:"-"`
}

// extractMessage retains the historical reasoning-first behavior used by
// Responses and generic endpoint fallbacks.
func extractMessage(chunks []string) extractedMessage {
	return extractMessageWithReasoningPolicy(chunks, false)
}

func extractMessageWithReasoningPolicy(chunks []string, preferReasoningContent bool) extractedMessage {
	var contentBuilder strings.Builder
	var reasoningBuilder strings.Builder
	finishReason := ""
	var reasoningDetails any
	reasoningDetailsPresent := false
	reasoningDetailsNull := false
	// See toolCallAccumulator for the logical-call model (arrival order,
	// non-unique wire indices, the maxLogicalToolCalls cap).
	acc := newToolCallAccumulator()

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
				Content          string                `json:"content"`
				Reasoning        string                `json:"reasoning"`
				ReasoningContent string                `json:"reasoning_content"`
				ReasoningDetails json.RawMessage       `json:"reasoning_details"`
				ToolCalls        []streamToolCallDelta `json:"tool_calls,omitempty"`
			} `json:"delta"`
			Message struct {
				Content          string                `json:"content"`
				Reasoning        string                `json:"reasoning"`
				ReasoningContent string                `json:"reasoning_content"`
				ReasoningDetails json.RawMessage       `json:"reasoning_details"`
				ToolCalls        []streamToolCallDelta `json:"tool_calls,omitempty"`
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
			if preferReasoningContent {
				if c.Delta.ReasoningContent != "" {
					reasoningBuilder.WriteString(c.Delta.ReasoningContent)
				} else if c.Delta.Reasoning != "" {
					reasoningBuilder.WriteString(c.Delta.Reasoning)
				} else if c.Message.ReasoningContent != "" {
					reasoningBuilder.WriteString(c.Message.ReasoningContent)
				} else if c.Message.Reasoning != "" {
					reasoningBuilder.WriteString(c.Message.Reasoning)
				}
			} else if c.Delta.Reasoning != "" {
				reasoningBuilder.WriteString(c.Delta.Reasoning)
			} else if c.Delta.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Delta.ReasoningContent)
			} else if c.Message.Reasoning != "" {
				reasoningBuilder.WriteString(c.Message.Reasoning)
			} else if c.Message.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Message.ReasoningContent)
			}
			for _, rawDetails := range []json.RawMessage{c.Delta.ReasoningDetails, c.Message.ReasoningDetails} {
				trimmed := bytes.TrimSpace(rawDetails)
				if len(trimmed) == 0 {
					continue
				}
				if trimmed[0] == '[' {
					var details []json.RawMessage
					if json.Unmarshal(rawDetails, &details) != nil {
						continue
					}
					if !reasoningDetailsPresent || reasoningDetailsNull {
						reasoningDetails = make([]json.RawMessage, 0, len(details))
						reasoningDetailsPresent = true
						reasoningDetailsNull = false
					}
					if accumulated, ok := reasoningDetails.([]json.RawMessage); ok {
						reasoningDetails = append(accumulated, details...)
					}
				} else if !reasoningDetailsPresent || reasoningDetailsNull {
					reasoningDetails = json.RawMessage(append([]byte(nil), rawDetails...))
					reasoningDetailsPresent = true
					reasoningDetailsNull = bytes.Equal(trimmed, []byte("null"))
				}
			}
			toolCalls := c.Delta.ToolCalls
			if len(toolCalls) == 0 {
				toolCalls = c.Message.ToolCalls
			}
			for _, tc := range toolCalls {
				acc.apply(tc)
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
	msg := extractedMessage{
		Content:                 content,
		Reasoning:               reasoning,
		ReasoningDetails:        reasoningDetails,
		ReasoningDetailsPresent: reasoningDetailsPresent,
		FinishReason:            finishReason,
	}
	if acc.droppedDeltas > 0 {
		log.Printf("WARN: extractMessage: logical tool-call cap (%d) reached; dropped %d tool-call delta(s) from excess calls", maxLogicalToolCalls, acc.droppedDeltas)
	}
	msg.ToolCalls = acc.finalize()
	return msg
}
