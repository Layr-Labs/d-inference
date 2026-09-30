package api

import (
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Thin HTTP adapter; request-local accounting lives in api/promptwork.
type requestCachePlans struct {
	body     func(string) ([]byte, error)
	plan     func(string, []byte) registry.CachePlan
	planWork func(string, []byte) promptwork.Result
	memo     promptwork.Memo
}

// Keep media eligibility identical for preflight, dispatch and alias-body
// replanning. Audio presence excludes text-cache planning without becoming a
// vision routing requirement or changing the request's token estimates.
func newRequestCachePlans(
	body func(string) ([]byte, error),
	plan func(string, []byte, bool) registry.CachePlan,
	requiresVision bool,
	parsed map[string]any,
) *requestCachePlans {
	return newRequestPromptWorkPlans(body,
		func(model string, encoded []byte, hasMedia bool) promptwork.Result {
			return promptwork.Result{Cache: plan(model, encoded, hasMedia)}
		}, requiresVision, parsed)
}

// The unified prompt-work path must retain the same audio/video cache
// ineligibility as the cache-only adapter, without changing vision routing.
func newRequestPromptWorkPlans(
	body func(string) ([]byte, error),
	plan func(string, []byte, bool) promptwork.Result,
	requiresVision bool,
	parsed map[string]any,
) *requestCachePlans {
	return &requestCachePlans{
		body: body,
		planWork: func(model string, encoded []byte) promptwork.Result {
			return plan(model, encoded, cachePlanHasMedia(requiresVision, parsed))
		},
	}
}

func (m *requestCachePlans) forModel(model string) registry.CachePlan {
	body, err := m.body(model)
	if err != nil {
		return registry.CachePlan{}
	}
	return m.forBody(model, body)
}
func (m *requestCachePlans) forBody(model string, body []byte) registry.CachePlan {
	return m.memo.Plan(model, body, func() promptwork.Result {
		if m.planWork != nil {
			return m.planWork(model, body)
		}
		return promptwork.Result{Cache: m.plan(model, body)}
	}).Cache
}
func (m *requestCachePlans) workForModel(model string) *protocol.PromptWork {
	body, err := m.body(model)
	if err != nil {
		return nil
	}
	m.forBody(model, body)
	return m.memo.Lookup(model, body)
}
