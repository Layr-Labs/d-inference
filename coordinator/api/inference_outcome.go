package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

const metricRequestTerminalShadow = "inference.request_terminal_shadow"

const (
	requestClassSuccess          = "success"
	requestClassProvider5xx      = "provider_5xx"
	requestClassMidStream        = "mid_stream"
	requestClassTimeout          = "timeout"
	requestClassIntegrationError = "integration_error"
	requestClassExcluded400      = "excluded_400"
	requestClassExcluded403      = "excluded_403"
	requestClassExcluded413      = "excluded_413"
	requestClassExcluded429      = "excluded_429"
)

type openRouterCredentialClassifier struct {
	keyIDs       map[string]struct{}
	fingerprints [][sha256.Size]byte
}

func newOpenRouterCredentialClassifier(keyIDs, fingerprintHex []string, logger *slog.Logger) openRouterCredentialClassifier {
	c := openRouterCredentialClassifier{keyIDs: make(map[string]struct{}, len(keyIDs))}
	for _, id := range keyIDs {
		if id = strings.TrimSpace(id); id != "" {
			c.keyIDs[id] = struct{}{}
		}
	}
	for range fingerprintHex {
		// Preallocate once; malformed values are skipped below.
		c.fingerprints = append(c.fingerprints, [sha256.Size]byte{})
	}
	valid := c.fingerprints[:0]
	for i, raw := range fingerprintHex {
		decoded, err := hex.DecodeString(strings.TrimSpace(raw))
		if err != nil || len(decoded) != sha256.Size {
			if logger != nil {
				logger.Warn("ignoring malformed OpenRouter credential fingerprint", "index", i)
			}
			continue
		}
		var fingerprint [sha256.Size]byte
		copy(fingerprint[:], decoded)
		valid = append(valid, fingerprint)
	}
	c.fingerprints = valid
	return c
}

func (c openRouterCredentialClassifier) matchesToken(token string) bool {
	if token == "" || len(c.fingerprints) == 0 {
		return false
	}
	sum := sha256.Sum256([]byte(token))
	matched := 0
	for i := range c.fingerprints {
		matched |= subtle.ConstantTimeCompare(sum[:], c.fingerprints[i][:])
	}
	return matched == 1
}

func (c openRouterCredentialClassifier) matchesKeyID(id string) bool {
	_, ok := c.keyIDs[id]
	return ok && id != ""
}

type inferenceOutcomeState struct {
	mu sync.Mutex

	startedAt  time.Time
	exact      bool
	model      string
	explicit   string
	endpoint   string
	credential openRouterCredentialClassifier
}

func (o *inferenceOutcomeState) markKeyID(id string) {
	if !o.credential.matchesKeyID(id) {
		return
	}
	o.mu.Lock()
	o.exact = true
	o.mu.Unlock()
}

func (o *inferenceOutcomeState) mark(model, class string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if model != "" {
		o.model = model
	}
	if class != "" {
		o.explicit = class
	}
}

func (o *inferenceOutcomeState) snapshot(status int) (exact bool, model, class, endpoint string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	class = o.explicit
	statusClass := classifyRequestTerminalStatus(status)
	if class == "" || statusClass != requestClassSuccess {
		class = statusClass
	}
	model = o.model
	if model == "" {
		model = "unknown"
	}
	return o.exact, model, class, o.endpoint
}

func classifyRequestTerminalStatus(code int) string {
	switch {
	case code == http.StatusBadRequest:
		return requestClassExcluded400
	case code == http.StatusForbidden:
		return requestClassExcluded403
	case code == http.StatusRequestEntityTooLarge:
		return requestClassExcluded413
	case code == http.StatusTooManyRequests:
		return requestClassExcluded429
	case code == http.StatusRequestTimeout, code == http.StatusGatewayTimeout:
		return requestClassTimeout
	case code == http.StatusUnauthorized, code == http.StatusPaymentRequired, code == http.StatusNotFound:
		return requestClassIntegrationError
	case code >= http.StatusInternalServerError || code == 0:
		return requestClassProvider5xx
	case code >= http.StatusBadRequest:
		return requestClassIntegrationError
	default:
		return requestClassSuccess
	}
}

func (s *Server) inferenceOutcome(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		state := &inferenceOutcomeState{
			startedAt:  time.Now(),
			exact:      s.openRouterCredentials.matchesToken(extractBearerToken(r)),
			endpoint:   r.URL.Path,
			credential: s.openRouterCredentials,
		}
		ctx := context.WithValue(r.Context(), ctxKeyInferenceOutcome, state)
		sw := &statusWriter{ResponseWriter: w}
		next(sw, r.WithContext(ctx))

		exact, model, class, endpoint := state.snapshot(sw.status)
		if !exact {
			return
		}
		s.ddIncr(metricRequestTerminalShadow, []string{
			"model:" + model,
			"class:" + class,
			"endpoint:" + inferenceEndpointLabel(endpoint),
		})
	}
}

func inferenceEndpointLabel(path string) string {
	switch path {
	case "/v1/chat/completions":
		return "chat_completions"
	case "/v1/responses":
		return "responses"
	case "/v1/completions":
		return "completions"
	case "/v1/messages":
		return "messages"
	default:
		return "unknown"
	}
}

func markInferenceOutcome(ctx context.Context, model, class string) {
	if state, ok := ctx.Value(ctxKeyInferenceOutcome).(*inferenceOutcomeState); ok {
		state.mark(model, class)
	}
}

func markInferenceOutcomeKeyID(ctx context.Context, id string) {
	if state, ok := ctx.Value(ctxKeyInferenceOutcome).(*inferenceOutcomeState); ok {
		state.markKeyID(id)
	}
}

func inferenceRequestStartedAt(ctx context.Context) (time.Time, bool) {
	if state, ok := ctx.Value(ctxKeyInferenceOutcome).(*inferenceOutcomeState); ok {
		return state.startedAt, true
	}
	return time.Time{}, false
}
