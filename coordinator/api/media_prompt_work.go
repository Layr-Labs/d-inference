package api

import (
	"context"
	"strings"
	"time"
)

// Optional metadata work never queues behind other media requests. Every
// parser has its own byte/node limits, and reads honor this short work budget.
var mediaMetadataSlots = make(chan struct{}, 8)

// mediaPromptTokens improves the routing estimate for a concrete native model.
// Alias/fallback traffic retains the existing estimate until candidate-specific
// media accounting can accompany the entire alias lifecycle. This is still a
// heuristic text/template count, never exact prompt/cache evidence.
func (s *Server) mediaPromptTokens(ctx context.Context, publicModel, model string, parsed map[string]any, fallback int) int {
	if publicModel != model || s.promptArtifacts == nil || s.registry == nil {
		return fallback
	}
	status, ok := s.promptArtifacts.Status(model)
	if !ok || !status.ArtifactReady || status.MediaProfile == nil ||
		!strings.EqualFold(status.ModelAggregateSHA256, s.registry.CatalogWeightHash(model)) {
		return fallback
	}
	select {
	case mediaMetadataSlots <- struct{}{}:
		defer func() { <-mediaMetadataSlots }()
	default:
		return fallback
	}
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	delta := 0
	status.MediaProfile.Walk(ctx, parsed, func(part map[string]any, tokens int) {
		old := 0
		switch part["type"] {
		case "image_url", "input_image", "image":
			old = imagePromptTokenCost
		case "video_url", "input_video", "video":
			old = videoPromptTokenCost
		case "input_audio", "audio_url":
			old = jsonValueLen(part) / 4
		}
		delta += tokens - old
	})
	if ctx.Err() != nil {
		return fallback
	}
	// Recheck the artifact after optional work, so a concurrently reconciled
	// catalog cannot silently reuse metadata from a prior active artifact.
	if !strings.EqualFold(status.ModelAggregateSHA256, s.registry.CatalogWeightHash(model)) {
		return fallback
	}
	return max(1, fallback+delta)
}
