package media

import (
	"context"
	"net/http"
	"strings"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

type Budget struct{ slots chan struct{} }

func NewBudget(limit int) *Budget { return &Budget{slots: make(chan struct{}, limit)} }

// TryAcquire never queues optional metadata work behind another media request.
func (b *Budget) TryAcquire() bool {
	select {
	case b.slots <- struct{}{}:
		return true
	default:
		return false
	}
}

func (b *Budget) Release() { <-b.slots }

type mediaArtifactSource interface {
	Status(string) (promptcontract.ProvisionStatus, bool)
}
type mediaCatalog interface{ CatalogWeightHash(string) string }

type MetadataDependencies struct {
	Artifacts            mediaArtifactSource
	Catalog              mediaCatalog
	Budget               *Budget
	ApplyTokenRateLimit  func(http.ResponseWriter, *http.Request, int, int) bool
	FirstContentDeadline func(string, int) time.Duration
}

// Estimator uses verified current artifact headers, never payload hashes
// or speculative shape models, to refine native-media routing token estimates.
type Estimator struct{ d MetadataDependencies }

func NewEstimator(d MetadataDependencies) *Estimator { return &Estimator{d: d} }

// Tokens improves the routing estimate for a concrete native model.
// Alias/fallback traffic retains the existing estimate until candidate-specific
// media accounting can accompany the entire alias lifecycle. This is still a
// heuristic text/template count, never exact prompt/cache evidence.
func (s *Estimator) Tokens(ctx context.Context, publicModel, model string, parsed map[string]any, fallback int) int {
	value, _ := s.Estimate(ctx, publicModel, model, parsed, fallback)
	return value
}

func (s *Estimator) Estimate(ctx context.Context, publicModel, model string, parsed map[string]any, fallback int) (int, bool) {
	if publicModel != model || s.d.Artifacts == nil || s.d.Catalog == nil {
		return fallback, false
	}
	status, ok := s.d.Artifacts.Status(model)
	if !ok || !status.ArtifactReady || status.MediaProfile == nil ||
		!strings.EqualFold(status.ModelAggregateSHA256, s.d.Catalog.CatalogWeightHash(model)) {
		return fallback, false
	}
	if !s.d.Budget.TryAcquire() {
		return fallback, false
	}
	defer s.d.Budget.Release()
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
	if !strings.EqualFold(status.ModelAggregateSHA256, s.d.Catalog.CatalogWeightHash(model)) {
		return fallback, false
	}
	return max(1, fallback+delta), known
}

// Recount corrects only the input-token term after a cost-gated
// URL fetch. It returns a duration for the original receive instant, never a
// new starting time. An exempt request remains exempt.
func (s *Estimator) Recount(w http.ResponseWriter, r *http.Request, publicModel, model string,
	parsed map[string]any, baseline, previous int, deadline time.Duration) (int, time.Duration, bool) {
	updated, known := s.Estimate(r.Context(), publicModel, model, parsed, baseline)
	if !known {
		return previous, deadline, true
	}
	if updated > previous && !s.d.ApplyTokenRateLimit(w, r, updated-previous, 0) {
		return previous, deadline, false
	}
	if updated != previous && deadline > 0 {
		deadline = s.d.FirstContentDeadline(model, updated)
	}
	return updated, deadline, true
}
