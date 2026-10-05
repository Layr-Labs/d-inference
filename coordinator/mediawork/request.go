package mediawork

import (
	"context"
	"encoding/base64"

	encodedreader "github.com/eigeninference/d-inference/coordinator/internal/mediawork/encodedreader"
)

// Walk reports improved counts only for recognized inline media. Unknown
// containers and unresolved URLs retain the caller's existing fallback. The
// callback and all media references are request-scoped and never retained.
func (p *Profile) Walk(ctx context.Context, request map[string]any, visit func(map[string]any, int)) {
	if p == nil {
		return
	}
	seen := 0
	content := func(value any) {
		parts, _ := value.([]any)
		for _, value := range parts {
			if ctx.Err() != nil || seen >= 64 {
				return
			}
			part, ok := value.(map[string]any)
			if !ok {
				continue
			}
			kind, _ := part["type"].(string)
			var tokens int
			var known bool
			switch kind {
			case "image_url", "input_image", "image":
				seen++
				tokens, known = p.EncodedImage(ctx, reference(part, "image_url"))
			case "video_url", "input_video", "video":
				seen++
				tokens, known = p.EncodedVideo(ctx, reference(part, "video_url"))
			case "input_audio":
				seen++
				audio, _ := part["input_audio"].(map[string]any)
				data, _ := audio["data"].(string)
				tokens, known = p.EncodedAudio(ctx, data, true)
			case "audio_url":
				seen++
				tokens, known = p.EncodedAudio(ctx, reference(part, "audio_url"), false)
			}
			if known && tokens > 0 {
				visit(part, tokens)
			}
		}
	}
	for _, field := range []string{"messages", "input"} {
		items, _ := request[field].([]any)
		for i, value := range items {
			if i >= 4096 || ctx.Err() != nil || seen >= 64 {
				return
			}
			item, ok := value.(map[string]any)
			if !ok {
				continue
			}
			if c, exists := item["content"]; exists {
				content(c)
			} else if item["type"] == "function_call_output" {
				content(item["output"])
			}
		}
	}
}

func reference(part map[string]any, field string) string {
	switch value := part[field].(type) {
	case string:
		return value
	case map[string]any:
		result, _ := value["url"].(string)
		return result
	}
	if source, ok := part["source"].(map[string]any); ok && source["type"] == "base64" {
		mime, _ := source["media_type"].(string)
		data, _ := source["data"].(string)
		if len(mime) > 128 || len(data) > base64.StdEncoding.EncodedLen(encodedreader.MaxEncodedBytes) {
			return ""
		}
		return "data:" + mime + ";base64," + data
	}
	return ""
}
