package api

// provider_body_memo.go memoizes, for ONE request, the provider-bound body of
// each candidate model and the routing verdicts derived from it. The chat
// handler needs that body for the resolved build (dispatch), for the alias
// fallback build the admission preflight probes, and again for the size
// verdict and routing traits of whichever build wins — and every one of those
// used to rebuild and re-serialize the body from scratch. Building is a full
// marshal (plus a parse+re-encode for the legacy cache-bust sizing), so a
// single request paid it three to five times for the same bytes.

import "github.com/eigeninference/d-inference/coordinator/registry"

// providerBodyEntry is one memoized candidate: the serialized body (or the
// error building it), and — computed lazily, once — the routing traits and
// protocol-0 size verdict routingTraitsForProviderBody derives from it.
type providerBodyEntry struct {
	body    []byte
	err     error
	sized   bool
	traits  registry.RequestTraits
	sizeErr error
}

// providerBodyMemo caches candidate bodies per model for the life of one
// request. It is single-goroutine (the handler's preprocessing runs inline).
type providerBodyMemo struct {
	build          func(model string) ([]byte, error)
	hasTools       bool
	requiresVision bool
	entries        map[string]*providerBodyEntry
}

func newProviderBodyMemo(build func(model string) ([]byte, error), hasTools, requiresVision bool) *providerBodyMemo {
	return &providerBodyMemo{
		build:          build,
		hasTools:       hasTools,
		requiresVision: requiresVision,
		entries:        make(map[string]*providerBodyEntry, 2),
	}
}

// entry returns the memoized candidate for model, building it on first use.
func (m *providerBodyMemo) entry(model string) *providerBodyEntry {
	if e, ok := m.entries[model]; ok {
		return e
	}
	e := &providerBodyEntry{}
	e.body, e.err = m.build(model)
	m.entries[model] = e
	return e
}

// body returns the candidate body for model.
func (m *providerBodyMemo) body(model string) ([]byte, error) {
	e := m.entry(model)
	return e.body, e.err
}

// seed records a body the handler already serialized for model (the dispatch
// body itself, or the fallback body after an alias rewrite) so the routing
// verdicts for that model reuse those exact bytes instead of rebuilding them.
// Valid only while parsed is fully reconciled for model — which is exactly
// when the handler holds such a body.
func (m *providerBodyMemo) seed(model string, body []byte) {
	m.entries[model] = &providerBodyEntry{body: body}
}

// reset forgets every candidate. Called whenever parsed is mutated in place
// after bodies were built (remote media inlined, alias fallback applied).
func (m *providerBodyMemo) reset() {
	clear(m.entries)
}

// sizing computes the routing traits and protocol-0 size verdict once per
// candidate.
func (m *providerBodyMemo) sizing(model string) *providerBodyEntry {
	e := m.entry(model)
	if e.err == nil && !e.sized {
		e.traits, e.sizeErr = routingTraitsForProviderBody(m.hasTools, e.body, m.requiresVision)
		e.sized = true
	}
	return e
}

// traits returns the body-derived routing traits for model. ok=false means the
// body could not be built; the caller falls back to constraint-only traits.
func (m *providerBodyMemo) traits(model string) (registry.RequestTraits, bool) {
	e := m.sizing(model)
	if e.err != nil {
		return registry.RequestTraits{}, false
	}
	return e.traits, true
}

// sizeError returns the protocol-0 cache-isolation size verdict for model, or
// nil when the body could not be built (a build failure is not a size failure).
func (m *providerBodyMemo) sizeError(model string) error {
	e := m.sizing(model)
	if e.err != nil {
		return nil
	}
	return e.sizeErr
}
