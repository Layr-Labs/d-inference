package response

import (
	"encoding/json"
	"math"
	"regexp"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

var thinkBlockPattern = regexp.MustCompile(`(?is)<think>(.*?)</think>\s*`)

func canonicalReasoningDetails(reasoning string, choiceIndex int) []types.ReasoningDetail {
	return []types.ReasoningDetail{{
		Type:   "reasoning.text",
		Text:   reasoning,
		ID:     "reasoning-text-" + strconv.Itoa(choiceIndex),
		Format: "unknown",
		Index:  0,
	}}
}

func normalizedChoiceIndex(raw any, fallback int) int {
	switch index := raw.(type) {
	case int:
		if index >= 0 {
			return index
		}
	case int64:
		converted := int(index)
		if index >= 0 && int64(converted) == index {
			return converted
		}
	case float64:
		intLimit := math.Ldexp(1, strconv.IntSize-1)
		if math.IsNaN(index) || math.IsInf(index, 0) || index < 0 || index >= intLimit || math.Trunc(index) != index {
			break
		}
		return int(index)
	case json.Number:
		if parsed, err := strconv.ParseInt(index.String(), 10, strconv.IntSize); err == nil && parsed >= 0 {
			return int(parsed)
		}
	}
	return fallback
}

func normalizeCompleteMessage(message map[string]any, choiceIndex int) {
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
	if reasoning, ok := message["reasoning"].(string); ok && reasoning != "" {
		message["reasoning_content"] = reasoning
		if _, hasDetails := message["reasoning_details"]; !hasDetails {
			message["reasoning_details"] = canonicalReasoningDetails(reasoning, choiceIndex)
		}
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
