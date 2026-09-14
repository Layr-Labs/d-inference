package dispatch

import (
	"net/http"
	"time"

	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// traits builds the routing traits for the current attempt, steering away from
// the most recently failed provider's binary version.
func (d *execution) traits() registry.RequestTraits {
	return registry.RequestTraits{
		HasTools:               d.hasTools,
		RequiresToolConstraint: d.requiresToolConstraint,
		ToolChoiceMode:         d.toolChoiceMode,
		ToolChoiceName:         d.toolChoiceName,
		ParallelToolCalls:      d.parallelToolCalls,
		AvoidVersion:           d.lastFailedVersion,
		MinPrefixCacheProtocol: d.minPrefixCacheProtocol,
	}
}

func (d *execution) configurePending(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.ConsumerEndpoint = d.consumerEndpoint
	pr.RequestedStopSequences = append(
		pr.RequestedStopSequences[:0], d.requestedStopSequences...)
	pr.MetadataDetails = d.metadataDetails
}

func (d *execution) excludedProviderIDs() []string {
	ids := make([]string, 0, len(d.excludeProviders))
	for id := range d.excludeProviders {
		ids = append(ids, id)
	}
	return ids
}

func (d *execution) shouldQueueCompatibleProvider(decision registry.RoutingDecision) bool {
	return d.providerBodyTooLargeErr != "" &&
		d.lastErrCode == http.StatusRequestEntityTooLarge &&
		decision.CapacityRejections > 0
}

// envTTFTTerminalReject is the kill switch for the terminal TTFT-rejection fix.
// A reservation that fails because every candidate exceeds the TTFT ceiling
// (errTTFTTooSlow) is DETERMINISTIC: it is computed from the same fleet-wide
// estimate on every scan, so re-running it within the same request cannot
// succeed. Default true: the dispatch ladder stops on the FIRST such rejection
// at ANY attempt and returns the same 429 the attempt-0 path always produced
// (prod: mid-ladder rejections previously looped to maxDispatchAttempts,
// re-running the doomed scan ~63x per request and writing a ttft_429 route row
// each time — 28% of inference_routes). Set =false to restore the legacy
// attempt-0-only fast path. Read live (not a Server field) following the
// cold.go flag pattern, so it stays confined to this file and is
// overridable in tests via t.Setenv.
const envTTFTTerminalReject = "EIGENINFERENCE_TTFT_TERMINAL_REJECT"

// ttftTerminalRejectEnabled reports whether a TTFT-too-slow reservation
// rejection terminates the dispatch ladder on any attempt. Default true.
func ttftTerminalRejectEnabled() bool {
	return envEnabledDefaultTrue(envTTFTTerminalReject)
}

// envJinjaTerminalReject is the kill switch for the deterministic
// template-render rejection stop (E4, 2026-07-15 platform errors deep dive).
// A provider error_reason of jinja_channel_tags / jinja_null_bridge /
// jinja_template means the model's chat template could not render the
// request's tool schemas or message history — the same body renders the same
// way on every provider, so failing over is pure waste (prod: 1.57 dispatch
// rows per jinja request, observed up to 17 attempts, 0% eventual success).
// Default true: the ladder stops on the FIRST jinja_* rejection at any
// attempt and surfaces one 422 model_capability invalid_request_error. Set
// =false to restore the legacy fail-over-on-500 behavior. Read live (not a
// Server field) following the envTTFTTerminalReject pattern, so it stays
// confined to this file and is overridable in tests via t.Setenv.
const envJinjaTerminalReject = "EIGENINFERENCE_JINJA_TERMINAL_REJECT"

// JinjaTerminalRejectEnabled reports whether a jinja_* provider rejection
// terminates the dispatch ladder. Default true.
func JinjaTerminalRejectEnabled() bool {
	return envEnabledDefaultTrue(envJinjaTerminalReject)
}

// JinjaTerminalRejectMessage is the OpenAI-style error body surfaced for a
// latched template-render failure — a curated model_capability message
// instead of the provider's raw Jinja backtrace (which names filters and
// template internals no API consumer can act on).
const JinjaTerminalRejectMessage = "the request's tool schemas or message history cannot be rendered by this model's chat template; simplify the tool parameter schemas or message structure, or use a different model"

// queueMaxTTFTMs returns the TTFT ceiling for queued requests. Public routes
// inherit the prompt-scaled admission threshold; self-route / prefer-owner paths
// are not subject to the public SLA ceiling.
//
// When hardReject is false (the default soft gate), a zero ceiling is returned
// so the scheduler's enforceTTFT path is disabled: candidates over the estimated
// deadline are no longer dropped (and no errTTFTTooSlow is produced). The router
// still ranks by cost (which is TTFT-weighted), so the fastest provider wins, but
// a request is served on the best-available provider instead of being rejected
// on a pessimistic prefill estimate.
func queueMaxTTFTMs(policy RoutePolicy, deadline time.Duration, hardReject bool) float64 {
	if policy.Enabled || policy.Prefer {
		return 0
	}
	if !hardReject {
		return 0
	}
	return float64(deadline.Milliseconds())
}

// rejectionReasonOversized is the rejection-ledger reason_code for a request the
// dispatch loop stopped because no provider can serve it (deterministic context
// overflow, or a transient-capacity shortage that exhausted
// maxCapacityClassRetries). Distinct from the preflight "context_exceeded" /
// "prompt_too_long" and the legacy dispatch-exhausted "unservable_token_budget".
const rejectionReasonOversized = "oversized_request"

// RejectionReasonQueueDeadline is the rejection-ledger reason_code for a
// request whose request-absolute first-content clock expired while it was
// still waiting in the coordinator queue. Nothing was dispatched — it is the
// queue's own terminal, kept distinct from first_chunk_timeout (a dispatched
// provider that produced no content in time) so telemetry stops conflating
// queue expiry with provider silence. Same retryable 429 + Retry-After.
const RejectionReasonQueueDeadline = "queue_deadline"

// errQueueDeadlineExpired is the latched error text for that terminal; the
// exhausted ladder keys the queue_deadline reason on it.
const errQueueDeadlineExpired = "first-content deadline expired while queued for a provider"

// RejectionReasonRoutingSaturated is the rejection-ledger reason_code for a
// request shed because no provider-selection scan slot freed up within its
// remaining first-content budget (Controller.routingScanSem — the coordinator
// itself was the bottleneck, 2026-09-01 collapse). Capacity-shaped: one
// retryable 429, uptime-neutral, zero providers contacted.
const RejectionReasonRoutingSaturated = "routing_saturated"

// rejectionReasonDeadlineUnreachable is the rejection-ledger reason for a
// request whose remaining absolute first-content budget was refused by one or
// more providers and whose untried candidates were then exhausted.
const rejectionReasonDeadlineUnreachable = attemptpolicy.ErrorReasonDeadlineUnreachable

// rejectionReasonTemplateRenderFailed is the rejection-ledger reason_code for
// a request the dispatch loop stopped because the model's chat template
// cannot render it (provider error_reason jinja_channel_tags /
// jinja_null_bridge / jinja_template — see envJinjaTerminalReject).
// Distinguishable from the StatusCode-driven stop's generic "client_error".
const rejectionReasonTemplateRenderFailed = "template_render_failed"
