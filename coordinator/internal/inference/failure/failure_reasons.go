package failure

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	ErrorReasonJinjaChannelTags          = "jinja_channel_tags"
	ErrorReasonJinjaNullBridge           = "jinja_null_bridge"
	ErrorReasonJinjaTemplate             = "jinja_template"
	ErrorReasonModelLoad                 = "model_load"
	ErrorReasonCapacityTimeout           = "capacity_timeout"
	ErrorReasonQueueFull                 = "queue_full"
	ErrorReasonTokenBudgetExhaust        = "token_budget_exhausted"
	ErrorReasonMediaMemoryUnavailable    = protocol.InferenceErrorReasonMediaMemoryUnavailable
	ErrorReasonRequestExceedsContext     = "request_exceeds_context"
	ErrorReasonRequestExceedsNode        = "request_exceeds_node"
	ErrorReasonRequestExceedsNodeBudget  = "request_exceeds_node_budget"
	ErrorReasonRequestExceedsBatchBudget = "request_exceeds_batch_token_budget"
	ErrorReasonCapacityBusy              = "capacity_busy"
	ErrorReasonDeadlineUnreachable       = "deadline_unreachable"
	ErrorReasonCancelled                 = "cancelled"
	ErrorReasonProviderError             = "provider_error"
	ErrorReasonClientError               = "client_error"
	// errorReasonToolNoncompliance (E5): the provider's typed 422 for a model
	// that failed a forced tool_choice contract (did not emit the required
	// call / emitted one outside the allowed set / exceeded the deferred
	// content limit). Output-dependent — a re-sample can comply — so 422 stays
	// on the normal bounded-failover path, NEVER in the terminal client-error
	// stop set (see isTerminalClientErrorCode).
	ErrorReasonToolNoncompliance = "tool_noncompliance"
	// errorReasonDraining (R2): the provider's typed refusal because it is
	// draining ahead of a restart/update. Transient capacity for failover
	// (another provider serves) that consumes NO transient-capacity retry,
	// derates NO gray-box state, and marks the provider draining
	// (registry.MarkDraining) so the next scan skips it.
	ErrorReasonDraining = protocol.InferenceErrorReasonDraining
	// errorReasonProviderRestart (R1): coordinator-internal marker stamped by
	// the registry on the pending-request flush of a GRACEFUL peer close
	// (restart/stop/update). Health-neutral through
	// isProviderHealthNeutralErrorReason; never accepted from the wire
	// (safeInferenceErrorReason does not emit it).
	errorReasonProviderRestart = protocol.InferenceErrorReasonProviderRestart
	ErrorReasonUnknown         = "unknown"
)

// isJinjaTemplateErrorReason reports whether a provider-supplied error_reason
// identifies a DETERMINISTIC chat-template render failure (the DAR-329/341
// provider vocabulary). The template renders the request's tool schemas and
// message history the same way on every provider, so these are request-shape /
// model-capability faults: the dispatch ladder stops on the first occurrence
// (E4, see dispatch.go), the provider takes no reputation hit
// (handleInferenceError), and route rows record class client_error — while the
// jinja_* reason itself is PRESERVED on the row, so the
// inference.error{reason:jinja_template} series keeps measuring real render
// failures rather than being silenced by reclassification.
func IsJinjaTemplateErrorReason(reason string) bool {
	switch NormalizeReason(reason) {
	case ErrorReasonJinjaChannelTags, ErrorReasonJinjaNullBridge, ErrorReasonJinjaTemplate:
		return true
	default:
		return false
	}
}

// isNonProviderFaultErrorReason reports whether a provider-supplied
// error_reason identifies a failure that is NOT the provider's fault:
//
//   - jinja_* template-render failures (isJinjaTemplateErrorReason, E4): the
//     REQUEST's tool schemas or message history cannot be rendered by the
//     model's chat template — deterministic for the request and identical on
//     every provider;
//   - tool_noncompliance (E5): the MODEL's sampled output broke a forced
//     tool_choice contract (did not emit the required call / emitted one
//     outside the allowed set / exceeded the deferred content limit) —
//     output-dependent, a re-sample can comply.
//
// This is the request/model-fault subset of the structured reasons exempted
// from reputation and provider-health tracking. The complete health-neutral
// vocabulary is isProviderHealthNeutralErrorReason, which also includes the
// request-clock-specific deadline_unreachable reason.
func IsNonProviderFaultErrorReason(reason string) bool {
	return IsJinjaTemplateErrorReason(reason) ||
		NormalizeReason(reason) == ErrorReasonToolNoncompliance
}

func IsDeadlineUnreachableErrorReason(reason string) bool {
	return NormalizeReason(reason) == ErrorReasonDeadlineUnreachable
}

// isProviderHealthNeutralErrorReason is the shared gate for reputation and all
// provider-health/capacity trackers. Request/model faults remain neutral as
// before; deadline_unreachable joins them because it describes the coordinator
// supplied remaining SLA, not provider sickness or capacity dishonesty.
// media_memory_unavailable is likewise specific to one media preparation:
// it does not disprove the same model's advertised text/KV capacity.
func IsProviderHealthNeutralErrorReason(reason string) bool {
	return IsNonProviderFaultErrorReason(reason) ||
		IsDeadlineUnreachableErrorReason(reason) ||
		NormalizeReason(reason) == ErrorReasonMediaMemoryUnavailable ||
		isProviderRestartErrorReason(reason)
}

// isProviderRestartErrorReason reports whether reason is the coordinator-
// internal provider_restart marker the registry stamps on the flushed
// terminals of a GRACEFUL peer close (registry.DisconnectWithReason). The
// requests fail over like any disconnect, but the terminal is health-neutral:
// no breaker/cooldown/ejection strike, no clear. An abrupt drop's flush
// carries no reason and keeps striking (the zombie discriminator).
func isProviderRestartErrorReason(reason string) bool {
	return NormalizeReason(reason) == errorReasonProviderRestart
}

// isDrainingErrorReason reports whether reason is the provider's typed
// draining refusal (R2): transient capacity that consumes no capacity retry
// and derates nothing; the provider is marked draining instead.
func IsDrainingErrorReason(reason string) bool {
	return NormalizeReason(reason) == ErrorReasonDraining
}

var validInferenceErrorReasons = map[string]struct{}{
	ErrorReasonJinjaChannelTags:          {},
	ErrorReasonJinjaNullBridge:           {},
	ErrorReasonJinjaTemplate:             {},
	ErrorReasonModelLoad:                 {},
	ErrorReasonCapacityTimeout:           {},
	ErrorReasonQueueFull:                 {},
	ErrorReasonTokenBudgetExhaust:        {},
	ErrorReasonMediaMemoryUnavailable:    {},
	ErrorReasonRequestExceedsContext:     {},
	ErrorReasonRequestExceedsNode:        {},
	ErrorReasonRequestExceedsNodeBudget:  {},
	ErrorReasonRequestExceedsBatchBudget: {},
	ErrorReasonCapacityBusy:              {},
	ErrorReasonDeadlineUnreachable:       {},
	ErrorReasonCancelled:                 {},
	ErrorReasonProviderError:             {},
	ErrorReasonClientError:               {},
	ErrorReasonToolNoncompliance:         {},
	ErrorReasonDraining:                  {},
	errorReasonProviderRestart:           {},
	ErrorReasonUnknown:                   {},
}

func NormalizeReason(reason string) string {
	reason = strings.ToLower(strings.TrimSpace(reason))
	reason = strings.ReplaceAll(reason, "-", "_")
	if reason == "" {
		return ""
	}
	if _, ok := validInferenceErrorReasons[reason]; ok {
		return reason
	}
	return ErrorReasonUnknown
}
