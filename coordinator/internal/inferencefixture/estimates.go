package inferencefixture

import (
	"encoding/json"
)

// legacyEstimates re-implements the pre-fusion estimators (independent walks,
// json.Marshal for the billing byte count) so the fused walk is pinned to them.
func Estimates(parsed map[string]any) (routing, billing, media int) {
	textTokens := func(s string) int {
		if s == "" {
			return 0
		}
		if t := len(s) / 4; t > 0 {
			return t
		}
		return 1
	}
	marshalLen := func(v any) int {
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		return len(b)
	}
	legacyCount := func(v any) int {
		if v == nil {
			return 0
		}
		if s, ok := v.(string); ok {
			return textTokens(s)
		}
		n := marshalLen(v)
		if n == 0 {
			return 0
		}
		if n/4 < 1 {
			return 1
		}
		return n / 4
	}
	legacyUpper := func(v any) int {
		if v == nil {
			return 0
		}
		if s, ok := v.(string); ok {
			return len(s)
		}
		return marshalLen(v)
	}
	contentTokens := func(content any) int {
		switch c := content.(type) {
		case string:
			return textTokens(c)
		case []any:
			total := 0
			for _, part := range c {
				pm, ok := part.(map[string]any)
				if !ok {
					continue
				}
				typ, _ := pm["type"].(string)
				switch {
				case typ == "text" || typ == "input_text":
					if s, ok := pm["text"].(string); ok {
						total += textTokens(s)
					}
				case typ == "image_url" || typ == "input_image" || typ == "image":
					total += imagePromptTokenCost
				case typ == "video_url" || typ == "input_video" || typ == "video":
					total += videoPromptTokenCost
				default:
					total += marshalLen(pm) / 4
				}
			}
			return total
		default:
			return legacyCount(content)
		}
	}
	countMedia := func(content any) int {
		parts, ok := content.([]any)
		if !ok {
			return 0
		}
		n := 0
		for _, part := range parts {
			if pm, ok := part.(map[string]any); ok {
				if typ, _ := pm["type"].(string); isMediaPartType(typ) {
					n++
				}
			}
		}
		return n
	}
	if v, ok := parsed["messages"]; ok {
		if arr, ok := v.([]any); ok {
			for _, m := range arr {
				mm, ok := m.(map[string]any)
				if !ok {
					routing += legacyCount(m)
					continue
				}
				routing += 4 + contentTokens(mm["content"])
				media += countMedia(mm["content"])
			}
		} else {
			routing += legacyCount(v)
		}
		billing += legacyUpper(v)
	}
	if v, ok := parsed["input"]; ok {
		switch x := v.(type) {
		case string:
			routing += legacyCount(x)
		case []any:
			for _, item := range x {
				switch m := item.(type) {
				case string:
					routing += legacyCount(m)
				case map[string]any:
					content, ok := m["content"]
					if !ok {
						routing += legacyCount(m)
						continue
					}
					routing += 4 + contentTokens(content)
					media += countMedia(content)
				default:
					routing += legacyCount(item)
				}
			}
		default:
			routing += legacyCount(v)
		}
		billing += legacyUpper(v)
	}
	if v, ok := parsed["prompt"]; ok {
		routing += legacyCount(v)
		billing += legacyUpper(v)
	}
	if routing == 0 {
		routing = legacyCount(parsed)
	}
	if billing == 0 {
		billing = legacyUpper(parsed)
	}
	return routing, billing, media
}

// isMediaPartType reports whether an OpenAI/OpenRouter content-part type denotes
// image or video input.
func isMediaPartType(t string) bool {
	switch t {
	// OpenAI chat (image_url/video_url), OpenAI Responses (input_image/input_video),
	// and Anthropic /v1/messages content blocks ({"type":"image"|"video","source":…}).
	case "image_url", "input_image", "image", "video_url", "input_video", "video":
		return true
	}
	return false
}

const (
	imagePromptTokenCost = 300
	videoPromptTokenCost = 1500
)

func PromptTokens(parsed map[string]any) int { routing, _, _ := Estimates(parsed); return routing }

func BillingTokens(parsed map[string]any) int { _, billing, _ := Estimates(parsed); return billing }
