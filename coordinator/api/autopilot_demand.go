package api

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

type autopilotDemandKey struct{}

// autopilotDemandRequest is owned by one logical HTTP request. Retries, queue
// transitions and speculative attempts annotate this object; only the handler
// exit consumes it. There is no request-ID set, content, or identity retention.
type autopilotDemandRequest struct {
	mu       sync.Mutex
	sample   registry.AutopilotDemandSample
	profile  *registry.RequestProfile
	reason   string
	armed    bool
	finished bool
}

func autopilotDemandFromContext(ctx context.Context) *autopilotDemandRequest {
	if ctx == nil {
		return nil
	}
	d, _ := ctx.Value(autopilotDemandKey{}).(*autopilotDemandRequest)
	return d
}

func (s *Server) beginAutopilotDemand(r *http.Request, receivedAt time.Time) (*http.Request, *autopilotDemandRequest) {
	if s == nil || s.registry == nil || !inferenceOutcomeEndpoint(r) || !s.registry.AutopilotEnabled() {
		return r, nil
	}
	d := &autopilotDemandRequest{sample: registry.AutopilotDemandSample{ReceivedAt: receivedAt}}
	return r.WithContext(context.WithValue(r.Context(), autopilotDemandKey{}, d)), d
}

// armAutopilotDemand runs only after the public handler's authentication,
// account/token limits, balance and request parsing checks. Further validation
// failures are excluded at finish. Scoped owner/serial traffic is not demand for
// the public fleet. An honest short request still counts; token length alone is
// not evidence of abuse.
func armAutopilotDemand(r *http.Request, p inferenceAdmissionParams) {
	d := autopilotDemandFromContext(r.Context())
	if d == nil || p.policy.enabled || p.policy.prefer || len(p.allowedProviderSerials) > 0 ||
		p.model == "" || len(p.model) > 256 || p.estimatedPromptTokens <= 0 || p.requestedMaxTokens <= 0 {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.armed || d.finished {
		return
	}
	d.sample.Model = p.model
	d.sample.PromptTokens = p.estimatedPromptTokens
	d.sample.RequestedMaxTokens = p.requestedMaxTokens
	d.sample.RequiresVision = p.requiresVision
	d.sample.HasTools = p.hasTools
	if p.traits != nil {
		d.sample.RequiresToolConstraint = p.traits.RequiresToolConstraint
	} else if p.traitsForModel != nil {
		d.sample.RequiresToolConstraint = p.traitsForModel(p.model).RequiresToolConstraint
	}
	d.armed = true
}

func setAutopilotDemandModel(r *http.Request, model string) {
	d := autopilotDemandFromContext(r.Context())
	if d == nil || model == "" || len(model) > 256 {
		return
	}
	d.mu.Lock()
	if !d.finished {
		d.sample.Model = model
	}
	d.mu.Unlock()
}

func bindAutopilotDemandProfile(r *http.Request, rp *registry.RequestProfile) {
	if d := autopilotDemandFromContext(r.Context()); d != nil {
		d.mu.Lock()
		d.profile = rp
		d.mu.Unlock()
	}
}

func annotateAutopilotDemandRejection(info rejectionInfo) {
	if info.r == nil {
		return
	}
	d := autopilotDemandFromContext(info.r.Context())
	if d == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.finished {
		return
	}
	// Coordinator-owned reasons are immediately folded into a closed vocabulary.
	// A free-form provider error, account ID, or request ID never enters state.
	d.reason = autopilotTerminalReason(info.reasonCode, info.httpStatus)
	if info.resolvedModel != "" && len(info.resolvedModel) <= 256 {
		d.sample.Model = info.resolvedModel
	}
}

func autopilotTerminalReason(reason string, status int) string {
	switch reason {
	case "machine_busy", "queue_full", "queue_timeout":
		return "capacity_shed"
	case "queue_deadline", "deadline_unreachable", "first_chunk_timeout", "ttft_too_slow":
		return "deadline"
	case "routing_saturated":
		return "routing_saturated"
	case "context_exceeded", "prompt_too_long", "oversized_request", "unservable_token_budget", "model_too_large":
		return "intrinsic_unservable"
	case "no_provider", "no_eligible_provider":
		return "no_eligible_provider"
	default:
		if status == http.StatusTooManyRequests {
			return "other_rate_limit"
		}
		if status >= http.StatusInternalServerError {
			return "provider_fault"
		}
		return "unknown"
	}
}

// finish consumes exactly once. This is offered logical demand, not a request
// success counter. Valid requests that fail or depart still consumed demand;
// intrinsic request limits and coordinator saturation are explicitly labeled so
// the controller must not mistake them for a removable model-placement deficit.
func (d *autopilotDemandRequest) finish(status int, clientDeparted bool) (registry.AutopilotDemandSample, bool) {
	if d == nil {
		return registry.AutopilotDemandSample{}, false
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.finished {
		return registry.AutopilotDemandSample{}, false
	}
	d.finished = true
	if !d.armed || d.sample.Model == "" || (status >= 400 && status < 500 && status != http.StatusTooManyRequests && status != 499) {
		return registry.AutopilotDemandSample{}, false
	}
	sample := d.sample
	sample.Reason = d.reason
	if sample.Reason == "" {
		sample.Reason = autopilotTerminalReason("", status)
	}
	// Unknown/account 429s are not actionable arrival pressure. Recognized
	// intrinsic/coordinator rejections remain separately diagnosable.
	if sample.Reason == "other_rate_limit" {
		return registry.AutopilotDemandSample{}, false
	}
	if clientDeparted || status == 499 {
		sample.Reason = "client_departure"
		return sample, true
	}
	sample.CapacityShed = status == http.StatusTooManyRequests &&
		(sample.Reason == "capacity_shed" || sample.Reason == "deadline")
	if status >= 200 && status < 300 {
		sample.Reason = "admitted"
		observeAutopilotCompletion(&sample, d.profile)
	}
	return sample, true
}

// A 200 header does not prove stream completion. Only a successful winning
// provider terminal plus completed consumer output supplies work/service data.
// Service time includes provider waiting and inference, but excludes coordinator
// queue/retry time and cold loading (which the placement controller costs apart).
func observeAutopilotCompletion(sample *registry.AutopilotDemandSample, rp *registry.RequestProfile) {
	if rp == nil || rp.ClientWriteErr.Load() || rp.ClientGoneUS.Load() > 0 || rp.DoneFlushedUS.Load() <= 0 {
		return
	}
	for _, ap := range rp.Attempts() {
		if !ap.Winning.Load() {
			continue
		}
		status, _, _, provider, _ := ap.Outcome()
		if status != "success" || provider != "completed" || !ap.ProviderCompleteObserved.Load() {
			return
		}
		prompt, output, ok := ap.TerminalUsage()
		if !ok || prompt < 0 || output < 0 {
			return
		}
		sample.Completed = true
		sample.Reason = "completed"
		sample.ObservedPromptTokens = prompt
		sample.ObservedOutputTokens = output
		accepted, complete := ap.AcceptedUS.Load(), ap.CompleteIngressUS.Load()
		if ap.DecisionSet && ap.Decision.StateMs == 0 && accepted > 0 && complete > accepted {
			sample.ServiceTime = time.Duration(complete-accepted) * time.Microsecond
		}
		return
	}
}

func (s *Server) finishAutopilotDemand(r *http.Request, d *autopilotDemandRequest, status int) {
	if d == nil || s == nil || s.registry == nil {
		return
	}
	if sample, ok := d.finish(status, r.Context().Err() != nil); ok {
		s.registry.RecordAutopilotDemand(sample)
	}
}
