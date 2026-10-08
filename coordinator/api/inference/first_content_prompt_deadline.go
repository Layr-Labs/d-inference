package inference

import (
	"context"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// PromptWorkDeadline reconciles the SLA's input-token term, not its ingress
// anchor. Enforcement was resolved before optional planning; zero remains an
// account exemption. Unqualified or no-longer-current counts retain that
// original fallback duration and cannot grant another planning attempt.
func (s *Owner) PromptWorkDeadline(publicModel, model string, fallback time.Duration, work *protocol.PromptWork) time.Duration {
	if fallback <= 0 || work == nil || work.Source != protocol.PromptWorkExact || s.promptArtifacts == nil || s.registry == nil {
		return fallback
	}
	status, ok := s.promptArtifacts.Status(model)
	if !ok || !status.ArtifactReady ||
		!strings.EqualFold(status.ModelAggregateSHA256, s.registry.CatalogWeightHash(model)) ||
		!work.IsQualifiedFor(status.ModelAggregateSHA256, status.PromptContractID) {
		return fallback
	}
	if modelpolicy.HasFirstContentPolicy(publicModel) {
		model = publicModel
	}
	// Calibration uncertainty bounds forecast work, not contractual input size.
	// Only exact counts correct this duration, in either direction; physical
	// reservations and later provider-side recounts remain unchanged.
	return s.FirstContentDeadline(model, work.PromptTokens)
}

// PromptWorkDeadlineForRequest freezes the account fallback and caller cutoff
// while permitting candidate-specific exact-count revalidation.
func (s *Owner) PromptWorkDeadlineForRequest(ctx context.Context, received time.Time, publicModel string, fallback time.Duration) func(string, *protocol.PromptWork) time.Duration {
	return func(model string, work *protocol.PromptWork) time.Duration {
		return firstcontent.DurationWithinContext(ctx, received, s.PromptWorkDeadline(publicModel, model, fallback, work))
	}
}
