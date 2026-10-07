package observation

import (
	"context"
	"net/http"
	"strings"
	"time"
)

func HasRequestMeta(ctx context.Context) bool { return requestMetaFromContext(ctx) != nil }

// WithRequestMeta accepts only a coordinator-minted identity, not client input.
func WithRequestMeta(ctx context.Context, coordID string, start time.Time) context.Context {
	return context.WithValue(ctx, requestMetaKey{}, &requestMeta{coordID: coordID, start: start})
}

func HTTPPathLabel(route string) string {
	if route == "" {
		return "unmatched"
	}
	return strings.ReplaceAll(route, " ", "-")
}

func MarkRequestStream(r *http.Request, stream bool) {
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		o.record.Stream = &stream
		o.mu.Unlock()
	}
}

func MarkCoordinatorExhausted(r *http.Request, exhausted bool) {
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		o.record.CoordinatorExhausted = exhausted
		o.mu.Unlock()
	}
}

// Terminal supplies a coordinator-owned terminal observation to egress code.
func Terminal(value string) ResponseTerminals { return ResponseTerminals{first: value} }
