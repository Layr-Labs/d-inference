package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// KV-backend segmentation for the v0.8.0 paged rollout (migration plan §16.1,
// Gate G5: "the coordinator can segment TTFT / decode-TPS / error-rate by KV
// backend").
//
// `BackendSlotCapacity.KVBackend` (protocol/messages.go:303) has ridden every
// heartbeat since the wire change landed, but nothing on the coordinator read
// it — the field arrived and was dropped, so no downstream consumer could group
// by it. This file is that reader. It keeps the last backend each SLOT reported
// and hands the API layer a bounded metric-tag value.
//
// SLOT granularity, never provider granularity. A box holds up to
// `maxModelSlots` (default 3) models at once, and during a staged rollout one
// box may legitimately serve paged for one model and contiguous for another.
// Keying on the provider alone would blend exactly the two populations this
// gate exists to separate — and it would look like it worked.
//
// TRI-STATE, preserved end to end. A pre-0.8.0 provider omits `kv_backend`
// entirely; `*string` decodes that to nil, and nil means UNKNOWN. It must never
// read as "contiguous", or the rollout dashboard books every legacy provider as
// a contiguous sample and shows a clean baseline composed entirely of old
// providers — the specific failure mode the pointer type exists to prevent.
//
// MEASUREMENT ONLY. Nothing here is consulted by routing, admission, scoring or
// shedding; the sole consumers are metric tags. Acting on the backend kind is a
// separate change with its own review.

// Metric-tag vocabulary. The first two are the shipped wire values; the rest
// encode the states a two-value vocabulary cannot express.
//
// A DogStatsD tag cannot be "absent but still groupable" the way an omitted
// JSON key can, so absence gets an explicit value here rather than being folded
// into a real kind. That is the same convention `routing.client_gone` already
// uses for an unknown chip family (api/prompt_buckets.go), and it is the
// opposite of the telemetry-EVENT rule (reference/telemetry-schema.md:223),
// where `kv_backend` is omitted rather than guessed because an event key can be
// absent without losing the row.
const (
	KVBackendPaged      = "paged"
	KVBackendContiguous = "contiguous"
	// KVBackendOther: the provider named a kind this build does not ship.
	// Forward-compatible (a future "paged_quantized" lands here) and, more to
	// the point, a cardinality fence — the value is untrusted provider input
	// and must never reach a metric tag verbatim.
	KVBackendOther = "other"
	// KVBackendUnspecified: a non-nil pointer to "". The provider is 0.8.0+ and
	// DID report the slot, but declined to name a backend. `omitempty` tests
	// the pointer, not the pointee, so that stays distinct from omission on the
	// wire; it stays distinct here too.
	KVBackendUnspecified = "unspecified"
	// KVBackendUnknown: no observation at all — a pre-0.8.0 provider, or a slot
	// this coordinator has never seen named in a heartbeat.
	KVBackendUnknown = "unknown"
)

// maxTrackedKVBackendSlots bounds the per-provider slot record. Slot models are
// untrusted provider input, so a box that heartbeats thousands of distinct slot
// models must not grow coordinator state without bound. A real box carries
// `maxModelSlots` (default 3) at a time and cycles through a handful more over
// a session, so the cap is unreachable in practice; past it, new models simply
// stay unattributed rather than being mis-attributed.
const maxTrackedKVBackendSlots = 64

// recordKVBackendsLocked folds the KV backend of every slot in a heartbeat into
// the provider's per-slot record. Caller must hold p.mu.
//
// STICKY on purpose: an entry survives its slot leaving the heartbeat. The
// provider reports only RESIDENT engine slots — `allSlots` comes from
// `engineV2Runtime.capacitySummary` (ProviderLoop+Capacity.swift:97) — so a
// slot that OOMs, crashes or is evicted mid-request vanishes from the report
// entirely. Without stickiness the 503s from a paged slot that just fell over
// would be attributed to "unknown", losing precisely the signal the gate exists
// to catch. The record lives on Provider, so it dies with the provider session
// and a reconnect starts clean.
//
// A nil KVBackend never overwrites an earlier observation: nil is "this
// provider says nothing", not an observation of anything.
func (p *Provider) recordKVBackendsLocked(bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	for i := range bc.Slots {
		slot := &bc.Slots[i]
		if slot.Model == "" || slot.KVBackend == nil {
			continue
		}
		if p.kvBackends == nil {
			p.kvBackends = make(map[string]string, len(bc.Slots))
		}
		if _, known := p.kvBackends[slot.Model]; !known && len(p.kvBackends) >= maxTrackedKVBackendSlots {
			continue
		}
		p.kvBackends[slot.Model] = *slot.KVBackend
	}
}

// kvBackendForModelLocked reports the last backend observed for this provider's
// slot serving model. observed == false means no heartbeat ever named one; the
// caller must not read that as any particular kind. An observed empty string is
// a real (if unhelpful) report and stays distinct from absence. Caller must
// hold p.mu.
func (p *Provider) kvBackendForModelLocked(model string) (kind string, observed bool) {
	kind, observed = p.kvBackends[model]
	return kind, observed
}

// SlotKVBackend returns the last KV backend the (provider, model) SLOT reported,
// and whether any heartbeat ever named one. Read-only; takes no registry write
// lock and never touches routing state.
func (r *Registry) SlotKVBackend(providerID, model string) (kind string, observed bool) {
	if r == nil || providerID == "" || model == "" {
		return "", false
	}
	p := r.GetProvider(providerID)
	if p == nil {
		return "", false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.kvBackendForModelLocked(model)
}

// SlotKVBackendTag is SlotKVBackend normalized to the metric-tag vocabulary.
func (r *Registry) SlotKVBackendTag(providerID, model string) string {
	return KVBackendTag(r.SlotKVBackend(providerID, model))
}

// KVBackendTag maps a tri-state slot observation onto the bounded metric-tag
// vocabulary. It NEVER invents a kind: an unobserved slot is "unknown", not
// "contiguous". Exported so the API layer tags metrics with the same vocabulary
// the registry stores.
func KVBackendTag(kind string, observed bool) string {
	if !observed {
		return KVBackendUnknown
	}
	switch kind {
	case KVBackendPaged, KVBackendContiguous:
		return kind
	case "":
		return KVBackendUnspecified
	default:
		return KVBackendOther
	}
}
