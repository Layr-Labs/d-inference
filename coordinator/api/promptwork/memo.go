// Package promptwork owns request-local prompt accounting and planning bounds.
// It never stores prompt content beyond the caller's synchronous planning call.
package promptwork

import (
	"context"
	"crypto/sha256"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Result struct {
	Cache registry.CachePlan
	Work  *protocol.PromptWork
	// retryPlanning distinguishes a temporary accounting-permit miss from a
	// completed plan. It remains local to this request and is never serialized.
	retryPlanning bool
}

type entry struct {
	digest [32]byte
	result Result
}

// Memo shares one result between preflight and every attempt, keyed by the
// concrete model and complete provider body (including tools and history).
// A rewritten fallback body cannot inherit a previous count. Entries and body
// digests live only for this HTTP request and are never logged or exported.
type Memo struct {
	mu      sync.Mutex
	entries map[string]entry
}

func (m *Memo) Plan(model string, body []byte, plan func() Result) Result {
	digest := sha256.Sum256(body)
	m.mu.Lock()
	defer m.mu.Unlock()
	if e, ok := m.entries[model]; ok && e.digest == digest {
		return clone(e.result)
	}
	result := plan()
	if result.retryPlanning {
		return result
	}
	if m.entries == nil {
		m.entries = make(map[string]entry, 2)
	}
	m.entries[model] = entry{digest: digest, result: clone(result)}
	return result
}

func (m *Memo) Lookup(model string, body []byte) *protocol.PromptWork {
	if m == nil {
		return nil
	}
	digest := sha256.Sum256(body)
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.entries[model]
	if !ok || e.digest != digest {
		return nil
	}
	return clone(e.result).Work
}

func clone(result Result) Result {
	if result.Work != nil {
		work := *result.Work
		result.Work = &work
	}
	return result
}

type contextKey struct{}

func WithMemo(ctx context.Context, memo *Memo) context.Context {
	return context.WithValue(ctx, contextKey{}, memo)
}
func FromContext(ctx context.Context, model string, body []byte) *protocol.PromptWork {
	memo, _ := ctx.Value(contextKey{}).(*Memo)
	return memo.Lookup(model, body)
}

// ForAttempt keeps unsupported or unplanned bodies explicitly heuristic while
// preserving an exact/calibrated result for the same request and body.
func ForAttempt(ctx context.Context, model string, body []byte, heuristic int) *protocol.PromptWork {
	if work := FromContext(ctx, model, body); work != nil {
		return work
	}
	return Heuristic(heuristic)
}
