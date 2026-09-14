package response

import (
	"encoding/json"
	"strings"
)

// streamToolCallDelta is one tool-call fragment from a chat.completion.chunk.
type streamToolCallDelta struct {
	Index    int    `json:"index"`
	ID       string `json:"id,omitempty"`
	Type     string `json:"type,omitempty"`
	Function struct {
		Name      string `json:"name,omitempty"`
		Arguments string `json:"arguments,omitempty"`
	} `json:"function,omitempty"`
}

// streamChunkChoice is a parsed choice from a chat.completion.chunk SSE line.
type streamChunkChoice struct {
	Index int `json:"index"`
	Delta struct {
		Content          string                `json:"content"`
		Reasoning        string                `json:"reasoning"`
		ReasoningContent string                `json:"reasoning_content"`
		ToolCalls        []streamToolCallDelta `json:"tool_calls,omitempty"`
	} `json:"delta"`
	FinishReason *string `json:"finish_reason"`
}

// parseStreamChunkChoices decodes the choices array from a provider SSE chunk.
// Returns nil for non-JSON lines, [DONE], and chunks without choices.
func parseStreamChunkChoices(chunk string) []streamChunkChoice {
	line := strings.TrimSpace(strings.TrimPrefix(chunk, "data: "))
	if line == "" || line == "[DONE]" {
		return nil
	}
	var parsed struct {
		Choices []streamChunkChoice `json:"choices"`
	}
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return nil
	}
	return parsed.Choices
}
