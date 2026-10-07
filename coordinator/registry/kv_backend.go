package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/kvbackend"
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
	// The crash-loop backend guard: the box's own watchdog counted 3
	// consecutive short-uptime restarts and flipped `.auto` to contiguous
	// for the tripping binary version (provider KVBackendGuard). The
	// kill switch's AUTOMATED sibling — but where kill_switch is good news,
	// this class is an incident marker: the box was crash-looping minutes
	// ago, and it stays contiguous until the next release or a manual
	// `darkbloom doctor --clear-backend-guard`.
	KVFallbackCrashLoopGuard = "crash_loop_guard"
	// Paged kernels failed their preflight on this box.
	KVFallbackKernelPreflight = "kernel_preflight"
	// Physical-capacity planning refused the pool before construction.
	KVFallbackPhysicalCapacity = "physical_capacity"
	// The layer layout is not paged-eligible.
	KVFallbackIneligible = "ineligible"
	// The pool was planned but could not be built at that size.
	KVFallbackPoolConstruction = "pool_construction_capacity"
	// DARKBLOOM_CBV2_PAGED_KV_DTYPE carried a value that parses as neither
	// float16 nor float32. Under `.auto` (the fleet default) the provider
	// degrades to contiguous with the typo in the detail tail; an explicit
	// paged selection still refuses. An operator-fixable config error, not
	// paged infrastructure failing — keep it separable from the classes
	// above on dashboards.
	KVFallbackInvalidDType = "invalid_dtype"
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
	KVFallbackCrashLoopGuard:   {},
	KVFallbackKernelPreflight:  {},
	KVFallbackPhysicalCapacity: {},
	KVFallbackIneligible:       {},
	KVFallbackPoolConstruction: {},
	KVFallbackInvalidDType:     {},
}

func (r *Registry) newKVBackendHistory(id string) *kvbackend.History {
	if r.kvBackendsFactory != nil {
		if history := r.kvBackendsFactory(id); history != nil {
			return history
		}
	}
	return &kvbackend.History{}
}

// recordKVBackendsLocked retains slot attribution under the existing provider lock.
func (p *Provider) recordKVBackendsLocked(bc *protocol.BackendCapacity) {
	if p.kvBackends == nil {
		p.kvBackends = &kvbackend.History{}
	}
	p.kvBackends.Record(bc)
}

// kvBackendForModelLocked reports the last observation for this provider's slot
// serving model. observed == false means no heartbeat ever named a backend; the
// caller must not read that as any particular kind, nor as "did not degrade".
// An observed empty Kind is a real (if unhelpful) report and stays distinct
// from absence. Caller must hold p.mu.
func (p *Provider) kvBackendForModelLocked(model string) (kvbackend.Observation, bool) {
	return p.kvBackends.Observe(model)
}

// SlotKVBackendTags resolves both metric dimensions for a provider the caller
// ALREADY holds, without a second registry lookup. Same single-observation
// guarantee as the Registry method below.
func (p *Provider) SlotKVBackendTags(model string) (backend, fallback string) {
	if p == nil || model == "" {
		return UnknownKVBackendTags()
	}
	p.mu.Lock()
	obs, observed := p.kvBackendForModelLocked(model)
	p.mu.Unlock()
	return KVBackendTag(obs.Kind, observed), KVBackendFallbackTag(obs.FallbackReason, observed)
}

// SlotKVBackendTags resolves BOTH KV-backend metric dimensions from ONE
// observation under a single lock. This is the ONLY exported slot accessor,
// deliberately: resolving the two dimensions separately lets a heartbeat land
// between the lookups and pair a pre-reload kind with a post-reload reason,
// manufacturing exactly the mis-attribution the fallback dimension was added
// to remove. Single-dimension accessors existed and were deleted for that
// reason; if you need one, take the pair and ignore a half.
func (r *Registry) SlotKVBackendTags(providerID, model string) (backend, fallback string) {
	if r == nil || providerID == "" {
		return UnknownKVBackendTags()
	}
	return r.GetProvider(providerID).SlotKVBackendTags(model)
}

// UnknownKVBackendTags is the metric pair for "no serving slot was ever
// resolved". Both dimensions are the explicit unknown value, never a real
// backend and never `none`: coercing an absent observation to
// contiguous/none would make the rollout dashboard show a clean baseline
// composed entirely of call sites that measured nothing.
func UnknownKVBackendTags() (backend, fallback string) {
	return KVBackendUnknown, KVFallbackUnknown
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
// would blow out tag cardinality; the raw pair stays in the session's
// kvbackend.History.
//
// NEVER returns "": every branch names a vocabulary constant. The API layer
// emits these values as metric tags without re-normalizing, and
// TestKVBackendTagsAreNeverEmpty is what keeps that safe.
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
	class = strings.TrimSpace(class)
	if _, known := knownKVFallbackClasses[class]; known {
		return class
	}
	return KVFallbackOther
}
