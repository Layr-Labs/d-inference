package inference

import (
	"context"
	"net/http"
	"time"

	infermedia "github.com/eigeninference/d-inference/coordinator/internal/inference/media"
)

// All owners share the existing process-wide optional metadata work limit.
var mediaMetadataBudget = infermedia.NewBudget(8)

func (s *Owner) mediaEstimator() *infermedia.Estimator {
	d := infermedia.MetadataDependencies{
		Budget:              mediaMetadataBudget,
		ApplyTokenRateLimit: s.applyTokenRateLimit, FirstContentDeadline: s.FirstContentDeadline,
	}
	if s.promptArtifacts != nil {
		d.Artifacts = s.promptArtifacts
	}
	if s.registry != nil {
		d.Catalog = s.registry
	}
	return infermedia.NewEstimator(d)
}

func (s *Owner) mediaPromptTokens(ctx context.Context, publicModel, model string, parsed map[string]any, fallback int) int {
	return s.mediaEstimator().Tokens(ctx, publicModel, model, parsed, fallback)
}

func (s *Owner) reconcileFetchedMedia(w http.ResponseWriter, r *http.Request, publicModel, model string, parsed map[string]any, baseline, previous int, deadline time.Duration) (int, time.Duration, bool) {
	return s.mediaEstimator().Recount(w, r, publicModel, model, parsed, baseline, previous, deadline)
}
