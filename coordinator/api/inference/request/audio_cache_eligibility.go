package request

// cachePlanHasMedia extends only text-cache eligibility. Audio is not vision:
// it must not alter routing estimates, billing, VisionImageCount or serving
// capabilities. Both API cache-plan call sites use this before the registry's
// existing HasMedia refusal, which happens before any sidecar request.
func CachePlanHasMedia(requiresVision bool, parsed map[string]any) bool {
	return requiresVision || requestHasAudioForCache(parsed)
}

// Inspect declared content positions only. Payload validation is deliberately
// not required: malformed/unsupported audio must never become a text-only key.
// Do not walk arbitrary maps, tool schemas, call arguments or string contents.
func requestHasAudioForCache(parsed map[string]any) bool {
	return contentHasAudioForCache(parsed["messages"]) ||
		contentHasAudioForCache(parsed["input"])
}

func contentHasAudioForCache(value any) bool {
	switch value := value.(type) {
	case []any:
		for _, item := range value {
			if contentHasAudioForCache(item) {
				return true
			}
		}
	case map[string]any:
		if kind, _ := value["type"].(string); kind == "input_audio" || kind == "audio_url" {
			return true
		}
		if contentHasAudioForCache(value["content"]) {
			return true
		}
		if value["type"] == "function_call_output" {
			return contentHasAudioForCache(value["output"])
		}
	}
	return false
}
