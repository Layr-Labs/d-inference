package outcome

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const InferenceErrorMetric = "inference.error"

// Recorder arbitrates each pending attempt's terminal route write and submits
// outcomes to the operational sink. Accounting remains with its lifecycle owner.
type Recorder struct {
	Store           store.Store
	Observation     *observation.Owner
	Metrics         *metrics.Reporter
	AttemptMetric   func(string, *store.InferenceRouteOutcome)
	CommittedMetric func(string, *store.InferenceRouteOutcome)
	TimingMetric    func(string, string, *store.InferenceRouteOutcome)
	CacheTerminal   func(*registry.PendingRequest, protocol.UsageInfo, bool, bool) bool
}

func (s *Recorder) Update(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil {
		return
	}
	// Loud guard: a negative raw TTFT was clamped to 0 (see
	// applyPendingRouteTelemetry). Emitting here — the single store-submit funnel
	// every terminal/commit outcome flows through — makes any regression of the
	// retried-request shared-Timing bug visible instead of silent.
	if outcome.InvalidTTFT {
		s.Metrics.InvalidTTFT(model, "negative")
	}
	if s.Store == nil || requestID == "" {
		return
	}
	s.InferenceError(model, outcome)
	s.AttemptMetric(model, outcome)
	s.CommittedMetric(model, outcome)
	s.TimingMetric(model, outcome.FinalStatus, outcome)
	// Off the request path: the batching sink pipelines this update with its
	// neighbours after the group's route inserts (route_telemetry_submit.go).
	s.Observation.SubmitRouteOutcome(requestID, attempt, model, outcome)
}

func (s *Recorder) InferenceError(model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil || outcome.ErrorReason == "" || outcome.FinalStatus == "" || outcome.FinalStatus == FinalStatusSuccess {
		return
	}
	tags := []string{"reason:" + outcome.ErrorReason}
	if model != "" {
		tags = append(tags, "model:"+model)
	}
	s.Observation.Incr(InferenceErrorMetric, tags)
}

func (s *Recorder) Pending(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	if pr == nil {
		return
	}
	terminal := outcome != nil && outcome.FinalStatus != ""
	if terminal {
		if !pr.MarkRouteOutcomeFinalized() {
			return
		}
		if ap := pr.Profile; ap != nil {
			ap.SetOutcome(outcome.FinalStatus, ProfileErrorReason(outcome), "", "", "")
			// Consumer-side synthetic terminals ARE the terminal half; a success
			// outcome is written at commit time and must wait for the provider's
			// terminal so the record carries settlement stamps and its profile.
			// A terminal already claimed by a provider frame is completed by
			// that frame once its provider outcome is written, so the record is
			// never built with an empty provider_outcome in between.
			if outcome.FinalStatus != FinalStatusSuccess {
				ap.CompleteTerminalUnlessClaimed()
			}
		}
		// Consumer-side synthetic terminals (notably registry.Disconnect's
		// ErrorCh delivery, local timeout, and grace expiry) do not pass through a
		// provider terminal handler. Close their cache-selection denominator as
		// unreported; the per-attempt claim makes this idempotent with provider
		// complete/error races.
		if s != nil {
			s.CacheTerminal(pr, protocol.UsageInfo{}, false, false)
		}
	}
	s.Update(pr.RequestID, pr.Attempt, pr.Model, outcome)
}
