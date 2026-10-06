// Package backend attributes request outcomes to the actual serving KV slot.
package backend

import "github.com/eigeninference/d-inference/coordinator/registry"

const (
	TagKey         = "kv_backend:"
	FallbackTagKey = "kv_backend_fallback:"
)

type Attribution struct {
	Backend  string
	Fallback string
}

func Unknown() Attribution {
	backend, fallback := registry.UnknownKVBackendTags()
	return Attribution{Backend: backend, Fallback: fallback}
}

func (a Attribution) AppendTags(dst []string) []string {
	return append(dst, TagKey+a.Backend, FallbackTagKey+a.Fallback)
}

func Resolve(r *registry.Registry, providerID, model string) Attribution {
	if r == nil {
		return Unknown()
	}
	backend, fallback := r.SlotKVBackendTags(providerID, model)
	return Attribution{Backend: backend, Fallback: fallback}
}

func ResolveProvider(p *registry.Provider, model string) Attribution {
	if p == nil {
		return Unknown()
	}
	backend, fallback := p.SlotKVBackendTags(model)
	return Attribution{Backend: backend, Fallback: fallback}
}

// Slot is an immutable dispatch-time observation, also retained with a terminal
// fault so later heartbeats cannot reattribute that fault to another slot.
type Slot struct {
	providerID string
	model      string
	backend    Attribution
}

func (s Slot) Matches(providerID, model string) bool {
	return s.providerID == providerID && s.model == model
}

func (s Slot) Attribution() Attribution { return s.backend }

// Latch belongs to one dispatch goroutine. Registry reads are needed only for
// a promoted live request, never between provider handoff and first content.
type Latch struct {
	registry *registry.Registry
	served   Slot
}

func NewLatch(r *registry.Registry) *Latch { return &Latch{registry: r} }

func (l *Latch) Capture(provider *registry.Provider, model string) Slot {
	if provider == nil || provider.ID == "" {
		return Slot{model: model, backend: Unknown()}
	}
	if l.served.Matches(provider.ID, model) {
		return l.served
	}
	return Slot{providerID: provider.ID, model: model, backend: ResolveProvider(provider, model)}
}

func (l *Latch) Note(provider *registry.Provider, pr *registry.PendingRequest, frozen bool) Slot {
	if pr == nil || pr.ProviderID == "" || frozen {
		return l.served
	}
	attr := Unknown()
	if provider != nil && provider.ID == pr.ProviderID {
		attr = ResolveProvider(provider, pr.Model)
	}
	l.served = Slot{providerID: pr.ProviderID, model: pr.Model, backend: attr}
	return l.served
}

func (l *Latch) Pin(provider *registry.Provider, model string) {
	if provider == nil || provider.ID == "" {
		return
	}
	l.served = l.Capture(provider, model)
}

func (l *Latch) Resolve(pr *registry.PendingRequest, frozen, genuineFault bool) Attribution {
	if pr != nil && pr.ProviderID != "" {
		if genuineFault {
			// A speculative loser cannot contaminate a survivor's delivered content.
			return Resolve(l.registry, pr.ProviderID, pr.Model)
		}
		if l.served.Matches(pr.ProviderID, pr.Model) {
			return l.served.backend
		}
		attr := Resolve(l.registry, pr.ProviderID, pr.Model)
		if !frozen {
			l.served = Slot{providerID: pr.ProviderID, model: pr.Model, backend: attr}
		}
		return attr
	}
	if l.served.providerID == "" {
		return Unknown()
	}
	return l.served.backend
}
