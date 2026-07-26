package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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

// Degrade-class vocabulary for `kv_backend_fallback_reason`. The wire value is
// free text the provider builds by interpolating an error, so it can NEVER
// reach a metric tag verbatim — these are the bounded classes it folds onto.
//
// The classes are not invented here: every producer already writes
// `"<class>: <detail>"` (or the bare `kill_switch`), so the class is the
// leading token and this vocabulary is the shipped producer set, read off
// EngineV2Factory+Production.swift and PagedKVPhysicalCapacityPolicy.swift.
const (
	// The kill switch (DARKBLOOM_CBV2_PAGED_KV=0) — a deliberate operator
	// rollback, and the one degrade class that is GOOD news.
	KVFallbackKillSwitch = "kill_switch"
	// Paged kernels failed their preflight on this box.
	KVFallbackKernelPreflight = "kernel_preflight"
	// Physical-capacity planning refused the pool before construction.
	KVFallbackPhysicalCapacity = "physical_capacity"
	// The layer layout is not paged-eligible.
	KVFallbackIneligible = "ineligible"
	// The pool was planned but could not be built at that size.
	KVFallbackPoolConstruction = "pool_construction_capacity"
	// KVFallbackNone: the slot WAS observed and named no reason. The
	// authoritative "this slot did not degrade" — the whole point of the
	// field. Never conflate it with KVFallbackUnknown.
	KVFallbackNone = "none"
	// KVFallbackOther: the provider named a class this build does not know.
	// Forward-compatible and, more to the point, the cardinality fence.
	KVFallbackOther = "other"
	// KVFallbackUnknown: the slot itself was never observed (a pre-0.8.0
	// provider, or a slot this coordinator has never seen). Says nothing
	// about whether it degraded.
	KVFallbackUnknown = "unknown"
)

// knownKVFallbackClasses is the shipped producer set. A class outside it tags
// as KVFallbackOther rather than reaching a metric verbatim.
var knownKVFallbackClasses = map[string]struct{}{
	KVFallbackKillSwitch:       {},
	KVFallbackKernelPreflight:  {},
	KVFallbackPhysicalCapacity: {},
	KVFallbackIneligible:       {},
	KVFallbackPoolConstruction: {},
}

// maxKVFallbackReasonBytes bounds the stored reason. It is untrusted provider
// input held for the life of a provider session across up to
// maxTrackedKVBackendSlots slots; the provider already caps it well under this,
// so the clamp only ever fires on a misbehaving or future build.
const maxKVFallbackReasonBytes = 256

// slotKVBackend is one slot's KV-backend observation. Kind and FallbackReason
// live in ONE value because they are only meaningful together and must be
// written together: recording them in two maps lets a slot that degraded, then
// reloaded clean, keep a stale reason next to a fresh kind — a permanent false
// degrade, which is the exact failure this field exists to prevent.
type slotKVBackend struct {
	// Kind is the resolved backend, verbatim from the wire.
	Kind string
	// FallbackReason is the degrade reason, "" when the slot did not
	// degrade. Because the pair is always written together, "" here is an
	// OBSERVATION of no degrade, not missing data.
	FallbackReason string
}

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
//
// The fallback reason is written IN LOCKSTEP with the kind, under that same
// nil-KVBackend gate — including when it is absent, which clears any earlier
// reason. That is not incidental: a slot that degrades, is reloaded and comes
// back clean reports a kind with no reason, and an update that only ever
// WROTE reasons would pin the old degrade to the healthy slot forever.
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
			p.kvBackends = make(map[string]slotKVBackend, len(bc.Slots))
		}
		if _, known := p.kvBackends[slot.Model]; !known && len(p.kvBackends) >= maxTrackedKVBackendSlots {
			continue
		}
		var reason string
		if slot.KVBackendFallbackReason != nil {
			reason = clampKVFallbackReason(*slot.KVBackendFallbackReason)
		}
		p.kvBackends[slot.Model] = slotKVBackend{
			Kind:           *slot.KVBackend,
			FallbackReason: reason,
		}
	}
}

// clampKVFallbackReason bounds an untrusted reason to maxKVFallbackReasonBytes.
// Truncation is from the tail, so the leading class token the metric groups on
// always survives.
func clampKVFallbackReason(reason string) string {
	if len(reason) <= maxKVFallbackReasonBytes {
		return reason
	}
	return reason[:maxKVFallbackReasonBytes]
}

// kvBackendForModelLocked reports the last observation for this provider's slot
// serving model. observed == false means no heartbeat ever named a backend; the
// caller must not read that as any particular kind, nor as "did not degrade".
// An observed empty Kind is a real (if unhelpful) report and stays distinct
// from absence. Caller must hold p.mu.
func (p *Provider) kvBackendForModelLocked(model string) (obs slotKVBackend, observed bool) {
	obs, observed = p.kvBackends[model]
	return obs, observed
}

// slotKVBackendObservation is the one lookup both dimensions come from.
// Read-only; takes no registry write lock and never touches routing state.
func (r *Registry) slotKVBackendObservation(providerID, model string) (slotKVBackend, bool) {
	if r == nil || providerID == "" || model == "" {
		return slotKVBackend{}, false
	}
	p := r.GetProvider(providerID)
	if p == nil {
		return slotKVBackend{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.kvBackendForModelLocked(model)
}

// SlotKVBackend returns the last KV backend the (provider, model) SLOT reported,
// and whether any heartbeat ever named one.
func (r *Registry) SlotKVBackend(providerID, model string) (kind string, observed bool) {
	obs, observed := r.slotKVBackendObservation(providerID, model)
	return obs.Kind, observed
}

// SlotKVBackendFallback returns the last degrade reason the (provider, model)
// SLOT reported, verbatim (clamped), and whether the slot was observed at all.
//
// Read it as a pair, exactly as the wire contract says: observed == false is
// UNKNOWN and says nothing about degrading; observed == true with reason == ""
// is the authoritative "this slot did not degrade". This is the queryable raw
// detail — "pool_construction_capacity: needed N, available M" — that the
// bounded metric tag deliberately throws away.
func (r *Registry) SlotKVBackendFallback(providerID, model string) (reason string, observed bool) {
	obs, observed := r.slotKVBackendObservation(providerID, model)
	return obs.FallbackReason, observed
}

// SlotKVBackendTags resolves BOTH KV-backend metric dimensions from ONE
// observation under a single lock. Callers must use this rather than two
// lookups: a heartbeat landing between them could pair a pre-reload kind with
// a post-reload reason, manufacturing exactly the mis-attribution the fallback
// dimension was added to remove.
func (r *Registry) SlotKVBackendTags(providerID, model string) (backend, fallback string) {
	obs, observed := r.slotKVBackendObservation(providerID, model)
	return KVBackendTag(obs.Kind, observed), KVBackendFallbackTag(obs.FallbackReason, observed)
}

// SlotKVBackendTag is the resolved-kind dimension alone.
func (r *Registry) SlotKVBackendTag(providerID, model string) string {
	backend, _ := r.SlotKVBackendTags(providerID, model)
	return backend
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

// KVBackendFallbackTag maps a slot's degrade reason onto the bounded metric-tag
// vocabulary. Exported alongside KVBackendTag so the API layer tags metrics with
// the same vocabulary the registry stores.
//
// `observed` is whether the SLOT was observed — the same flag KVBackendTag
// takes, and the reason the two dimensions must be resolved together. The
// three-way split is the entire point of the field:
//
//	!observed            -> unknown  (pre-0.8.0 provider; nothing is known)
//	observed, reason ""  -> none     (authoritative: this slot did not degrade)
//	observed, reason set -> <class>  (this slot degraded, and why)
//
// A degrade class is the leading token of the reason, which every producer
// writes as "<class>: <detail>" (or the bare "kill_switch"). The detail is
// dropped here on purpose — it embeds byte counts and error strings, which
// would blow out tag cardinality; SlotKVBackendFallback keeps it queryable.
func KVBackendFallbackTag(reason string, observed bool) string {
	if !observed {
		return KVFallbackUnknown
	}
	if reason == "" {
		return KVFallbackNone
	}
	class := reason
	if i := strings.IndexByte(class, ':'); i >= 0 {
		class = class[:i]
	}
	if _, known := knownKVFallbackClasses[strings.TrimSpace(class)]; known {
		return strings.TrimSpace(class)
	}
	return KVFallbackOther
}
