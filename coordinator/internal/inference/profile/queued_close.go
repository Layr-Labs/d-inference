package profile

import (
	"context"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func DispatchErrorClass(text string) string {
	if strings.Contains(text, providerwire.ErrBodyTooLarge.Error()) {
		return outcome.ErrorClassClientError
	}
	switch text {
	case "insufficient funds for provider price":
		return "insufficient_funds"
	case "no provider with E2E encryption":
		return "encryption_missing"
	case "provider public key invalid", "failed to encrypt request", "failed to generate session keys", "failed to marshal request":
		return "encryption_error"
	case providerwire.DeadlineExpiredMessage:
		return "first_chunk_timeout"
	default:
		return "provider_error"
	}
}

func CloseUndispatched(ap *registry.AttemptProfile, text string, code int) {
	observation.CloseUndispatchedAttempt(ap, DispatchErrorClass(text), code)
}

// CloseQueued closes only the unsent placeholder's terminal half. Recorded
// route error text wins over the default synthesized from the queue wait exit.
func CloseQueued(ctx context.Context, ap *registry.AttemptProfile, text string, code int) {
	if code == 0 {
		gone := ctx != nil && ctx.Err() != nil
		if gone {
			code = 499
		} else {
			code = http.StatusTooManyRequests
		}
		if text == "" {
			if gone {
				text = "client_gone"
			} else {
				text = "queue_rejected"
			}
		}
	}
	CloseUndispatched(ap, text, code)
}
