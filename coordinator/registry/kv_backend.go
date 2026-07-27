package registry

import (
	"strings"
	"unicode/utf8"

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

// maxKVFallbackReasonBytes bounds the stored reason. It is untrusted provider
// input held for the life of a provider session across up to
// maxTrackedKVBackendSlots slots.
//
// DELIBERATELY ABOVE THE PRODUCER'S BOUND, not equal to it. The Swift provider
// clamps to 200 Characters in EngineV2Bridge.heartbeatFallbackReason, so a
// conforming build never reaches this clamp — it only fires on a misbehaving
// or future one. Keeping the coordinator's bound strictly looser means the two
// cannot fight over a legitimate reason, and keeping it AT ALL is the point:
// this side of the trust boundary must not depend on the other side having
// behaved. Raise the provider's bound first if it ever needs to grow.
//
// A grapheme cluster can be up to ~4 bytes in UTF-8, so 200 Characters can be
// ~800 bytes; the difference is why this is not "200 too".
const maxKVFallbackReasonBytes = 1024

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
//
// RUNE-SAFE. A plain reason[:n] byte slice can cut a multi-byte rune in half,
// and these reasons interpolate errors straight out of MLX/Metal — a
// non-ASCII path or device name is entirely possible. The trailing fragment
// would then be invalid UTF-8, which Postgres rejects on the route-outcome
// write and Go renders as U+FFFD in logs. Backing up to the last rune boundary
// costs at most three bytes of a 1 KiB tail.
func clampKVFallbackReason(reason string) string {
	if len(reason) <= maxKVFallbackReasonBytes {
		return reason
	}
	cut := maxKVFallbackReasonBytes
	for cut > 0 && !utf8.RuneStart(reason[cut]) {
		cut--
	}
	return reason[:cut]
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
//
// Unexported because nothing outside this package needs the RAW pair — the
// verbatim reason ("pool_construction_capacity: needed N, available M") is
// deliberately not what metrics carry. Package tests use it to assert what
// clampKVFallbackReason stored; production goes through SlotKVBackendTags.
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
// would blow out tag cardinality; the raw pair stays available in-package
// through slotKVBackendObservation.
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
