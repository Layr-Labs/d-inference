package api

import (
	"context"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// promptWorkDeadline reconciles the SLA's input-token term, not its ingress
// anchor. Enforcement was resolved before optional planning; zero remains an
// account exemption. Unqualified or no-longer-current counts retain that
// original fallback duration and cannot grant another planning attempt.
func (s *Server) promptWorkDeadline(publicModel, model string, fallback time.Duration, work *protocol.PromptWork) time.Duration {
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

// firstContentDurationWithinContext preserves an earlier caller cutoff in the
// scheduler and provider wire budget as well as in blocking HTTP operations.
// A cutoff already before ingress stays enabled and expired, never exempt.
func firstContentDurationWithinContext(ctx context.Context, received time.Time, duration time.Duration) time.Duration {
	if duration <= 0 || received.IsZero() {
		return duration
	}
	if cutoff, ok := ctx.Deadline(); ok && cutoff.Before(received.Add(duration)) {
		return max(time.Nanosecond, cutoff.Sub(received))
	}
	return duration
}

func (s *Server) promptWorkDeadlineForRequest(ctx context.Context, received time.Time, publicModel string, fallback time.Duration) func(string, *protocol.PromptWork) time.Duration {
	return func(model string, work *protocol.PromptWork) time.Duration {
		return firstContentDurationWithinContext(ctx, received, s.promptWorkDeadline(publicModel, model, fallback, work))
	}
}

// setPromptWorkDeadlines carries both ingress-anchored token terms until a
// candidate's renderer qualifies one. The larger envelope bounds unselected
// work; only reservation may turn it into a provider's actual wire cutoff.
func setPromptWorkDeadlines(pr *registry.PendingRequest, received time.Time, fallback, qualified time.Duration) {
	if pr == nil || received.IsZero() || fallback <= 0 {
		return
	}
	pr.FirstContentFallbackDeadline = received.Add(fallback)
	if qualified > 0 && qualified != fallback {
		pr.FirstContentQualifiedDeadline = received.Add(qualified)
	}
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
}

// configurePromptWorkDeadlines is run for direct, queued, retry and hedge
// requests immediately before reservation. Revalidation can withdraw stale
// exact evidence; it never grants a fresh planning or request clock.
func (d *dispatchState) configurePromptWorkDeadlines(pr *registry.PendingRequest) {
	if d.promptDeadlineForWork == nil {
		return
	}
	qualified := d.promptDeadlineForWork(d.model, pr.PromptWork)
	setPromptWorkDeadlines(pr, timingReceivedAt(d.timing), d.fallbackDeadline, qualified)
}
