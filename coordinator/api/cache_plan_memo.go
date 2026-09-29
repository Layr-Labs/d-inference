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
