package retry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// AttemptFailure is the normalized evidence passed from a terminal ingress to
// retry classification and the failed attempt's route outcome. An explicit live
// zero budget takes precedence over a heartbeat just like any other live budget.
type AttemptFailure struct {
	Message        protocol.InferenceErrorMessage
	ProviderBudget int64
}

func ProviderFailure(provider *registry.Provider, model string, msg protocol.InferenceErrorMessage) AttemptFailure {
	msg = failure.NormalizeInternalError(msg)
	budget := int64(0)
	if provider != nil {
		budget = provider.ReportedTokenBudgetMaxForModel(model)
	}
	if msg.AvailableTokenBudget != nil {
		budget = *msg.AvailableTokenBudget
	}
	return AttemptFailure{Message: msg, ProviderBudget: budget}
}

// CoordinatorFailure replaces all typed provider evidence, preventing a previous
// terminal cause, partial usage or live capacity quote from leaking into a retry.
func CoordinatorFailure(text string, code int) AttemptFailure {
	return AttemptFailure{Message: protocol.InferenceErrorMessage{Error: text, StatusCode: code}}
}

func (f AttemptFailure) RouteOutcome(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	msg := f.Message
	var class string
	admittedButFailed := false
	switch {
	case failure.IsDeadlineUnreachableErrorReason(msg.ErrorReason):
		class = outcome.ErrorClassDeadlineUnreachable
	case outcome.IsTerminalClientErrorCode(msg.StatusCode) || failure.IsNonProviderFaultErrorReason(msg.ErrorReason):
		class = outcome.ErrorClassClientError
	default:
		class = "provider_error"
		if msg.CoordinatorCause.IsProviderDisconnect() {
			class = "provider_disconnect_pre_commit"
		}
		admittedButFailed = true
	}
	out := ErrorRouteOutcome(pr, "error", class, msg)
	out.AdmittedButFailed = admittedButFailed
	outcome.ApplyAttemptUsage(out, msg.AttemptUsage)
	return out
}

func ErrorRouteOutcome(pr *registry.PendingRequest, status, class string, msg protocol.InferenceErrorMessage) *store.InferenceRouteOutcome {
	reason, text := "", ""
	if UsesProviderErrorText(class) {
		reason, text = msg.ErrorReason, msg.Error
	}
	out := outcome.RouteOutcomeWithReason(status, class, msg.StatusCode, reason, text)
	outcome.ApplyPendingRouteTelemetry(out, pr)
	return out
}

func UsesProviderErrorText(class string) bool {
	class = strings.ToLower(strings.TrimSpace(class))
	return class == failure.ErrorReasonProviderError ||
		class == outcome.ErrorClassDeadlineUnreachable ||
		class == outcome.ErrorClassClientError ||
		strings.HasPrefix(class, "provider_error") ||
		strings.HasPrefix(class, "provider_disconnect") ||
		strings.Contains(class, "provider_incomplete")
}
