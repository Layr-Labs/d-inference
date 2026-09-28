package api

import (
	"bytes"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// requestCachePlans shares exact planning between preflight and dispatch. A
// fallback can rebuild the body even for an already visited model, so model ID
// alone is not a sufficient key. Entries live only for this HTTP request.
type requestCachePlans struct {
	body    func(string) ([]byte, error)
	plan    func(string, []byte) registry.CachePlan
	entries map[string]requestCachePlan
}

type requestCachePlan struct {
	body []byte
	plan registry.CachePlan
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
	return &requestCachePlans{
		body: body,
		plan: func(model string, encoded []byte) registry.CachePlan {
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
	if entry, ok := m.entries[model]; ok && bytes.Equal(entry.body, body) {
		return entry.plan
	}
	plan := m.plan(model, body)
	if m.entries == nil {
		m.entries = make(map[string]requestCachePlan, 2)
	}
	// Provider bodies are replaced, never modified in place after serialization.
	m.entries[model] = requestCachePlan{body: body, plan: plan}
	return plan
}
