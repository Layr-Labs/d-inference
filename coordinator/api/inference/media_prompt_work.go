package inference

import (
	"context"
	"net/http"
	"strings"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// Optional metadata work never queues behind other media requests. Every
// parser has its own byte/node limits, and reads honor this short work budget.
var mediaMetadataSlots = make(chan struct{}, 8)

// mediaPromptTokens improves the routing estimate for a concrete native model.
// Alias/fallback traffic retains the existing estimate until candidate-specific
// media accounting can accompany the entire alias lifecycle. This is still a
// heuristic text/template count, never exact prompt/cache evidence.
func (s *Owner) mediaPromptTokens(ctx context.Context, publicModel, model string, parsed map[string]any, fallback int) int {
	value, _ := s.mediaPromptEstimate(ctx, publicModel, model, parsed, fallback)
	return value
}

func (s *Owner) mediaPromptEstimate(ctx context.Context, publicModel, model string, parsed map[string]any, fallback int) (int, bool) {
	if publicModel != model || s.promptArtifacts == nil || s.registry == nil {
		return fallback, false
	}
	status, ok := s.promptArtifacts.Status(model)
	if !ok || !status.ArtifactReady || status.MediaProfile == nil ||
		!strings.EqualFold(status.ModelAggregateSHA256, s.registry.CatalogWeightHash(model)) {
		return fallback, false
	}
	select {
	case mediaMetadataSlots <- struct{}{}:
		defer func() { <-mediaMetadataSlots }()
	default:
		return fallback, false
	}
	ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	delta, known := 0, false
	status.MediaProfile.Walk(ctx, parsed, func(part map[string]any, tokens int) {
		known = true
		old := 0
		switch part["type"] {
		case "image_url", "input_image", "image":
			old = inreq.ImagePromptTokenCost
		case "video_url", "input_video", "video":
			old = inreq.VideoPromptTokenCost
		case "input_audio", "audio_url":
			old = inreq.JsonValueLen(part) / 4
		}
		delta += tokens - old
	})
	if ctx.Err() != nil || !known {
		return fallback, false
	}
	// Recheck the artifact after optional work, so a concurrently reconciled
	// catalog cannot silently reuse metadata from a prior active artifact.
	if !strings.EqualFold(status.ModelAggregateSHA256, s.registry.CatalogWeightHash(model)) {
		return fallback, false
	}
	return max(1, fallback+delta), known
}

// reconcileFetchedMedia corrects only the input-token term after a cost-gated
// URL fetch. It returns a duration for the original receive instant, never a
// new starting time. An exempt request remains exempt.
func (s *Owner) reconcileFetchedMedia(w http.ResponseWriter, r *http.Request, publicModel, model string,
	parsed map[string]any, baseline, previous int, deadline time.Duration) (int, time.Duration, bool) {
	updated, known := s.mediaPromptEstimate(r.Context(), publicModel, model, parsed, baseline)
	if !known {
		return previous, deadline, true
	}
	if updated > previous && !s.applyTokenRateLimit(w, r, updated-previous, 0) {
		return previous, deadline, false
	}
	if updated != previous && deadline > 0 {
		deadline = s.FirstContentDeadline(model, updated)
	}
	return updated, deadline, true
}
