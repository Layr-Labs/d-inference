package catalog

import (
	"strings"
)

// deprecationDateFromMetadata extracts the optional "deprecation_date" string
// from a model's registry metadata, returning "" when it is absent or empty.
func deprecationDateFromMetadata(meta map[string]any) string {
	if dd, ok := meta["deprecation_date"].(string); ok {
		return dd
	}
	return ""
}

// openRouterIsReady decides whether a model is live on OpenRouter. This is a
// launch/staging flag, NOT a live-capacity signal — transient capacity is
// handled by 429s. Active catalog models default to ready; an operator can
// stage a model by setting metadata "openrouter_is_ready": false (or the alias
// "openrouter_staged": true).
func openRouterIsReady(meta map[string]any) bool {
	if meta == nil {
		return true
	}
	if v, ok := meta["openrouter_is_ready"].(bool); ok {
		return v
	}
	if staged, ok := meta["openrouter_staged"].(bool); ok {
		return !staged
	}
	return true
}

const huggingFaceIDMetadataKey = "hugging_face_id"

// huggingFaceIDForModel returns the exact Hugging Face repository OpenRouter
// should inspect. Most concrete model ids are already Hugging Face paths; an
// explicit metadata value supports internal routing ids without conflating the
// two identities.
func huggingFaceIDForModel(modelID string, meta map[string]any) string {
	if id, ok := meta[huggingFaceIDMetadataKey].(string); ok {
		if id = strings.TrimSpace(id); id != "" {
			return id
		}
	}
	return modelID
}

// openRouterSlug returns the OpenRouter marketplace slug for a model: an
// operator override from registry metadata ("openrouter_slug") if present,
// otherwise the model id itself.
//
// OpenRouter's provider spec leaves the slug underspecified and its own example
// sets slug == id, so the globally unique model id is a safe, collision-free
// default. Operators map a model onto an existing marketplace
// slug (e.g. "qwen/qwen3.5-9b") explicitly via the openrouter_slug metadata
// override / the admin openrouter-slug action.
func openRouterSlug(modelID string, meta map[string]any) string {
	if meta != nil {
		if s, ok := meta["openrouter_slug"].(string); ok && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return modelID
}
