package routeplan

import (
	"context"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Thin HTTP adapter; request-local accounting lives in api/promptwork.
type Memo struct {
	body     func(string) ([]byte, error)
	planWork func(string, []byte) promptwork.Result
	memo     promptwork.Memo
}

// WithContext shares the memo with later dispatch and retry accounting.
func (m *Memo) WithContext(ctx context.Context) context.Context {
	return promptwork.WithMemo(ctx, &m.memo)
}

// The unified prompt-work path must retain the same audio/video cache
// ineligibility as the cache-only adapter, without changing vision routing.
func New(
	body func(string) ([]byte, error),
	plan func(string, []byte, bool) promptwork.Result,
	requiresVision bool,
	parsed map[string]any,
) *Memo {
	return &Memo{
		body: body,
		planWork: func(model string, encoded []byte) promptwork.Result {
			return plan(model, encoded, inreq.CachePlanHasMedia(requiresVision, parsed))
		},
	}
}

func (m *Memo) ForModel(model string) registry.CachePlan {
	body, err := m.body(model)
	if err != nil {
		return registry.CachePlan{}
	}
	return m.ForBody(model, body)
}

func (m *Memo) ForBody(model string, body []byte) registry.CachePlan {
	return m.memo.Plan(model, body, func() promptwork.Result {
		return m.planWork(model, body)
	}).Cache
}

func (m *Memo) WorkForModel(model string) *protocol.PromptWork {
	body, err := m.body(model)
	if err != nil {
		return nil
	}
	m.ForBody(model, body)
	return m.memo.Lookup(model, body)
}
