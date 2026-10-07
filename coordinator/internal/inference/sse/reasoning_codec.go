package sse

import (
	"encoding/json"
	"math"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

func CanonicalReasoningDetails(reasoning string, choiceIndex int) []types.ReasoningDetail {
	return []types.ReasoningDetail{{
		Type:   "reasoning.text",
		Text:   reasoning,
		ID:     "reasoning-text-" + strconv.Itoa(choiceIndex),
		Format: "unknown",
		Index:  0,
	}}
}

func NormalizedChoiceIndex(raw any, fallback int) int {
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
