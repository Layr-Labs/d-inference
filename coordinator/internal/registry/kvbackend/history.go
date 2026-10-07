// Package kvbackend retains session-local KV backend observations for metric attribution.
package kvbackend

import (
	"unicode/utf8"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// MaxFallbackReasonBytes bounds the stored reason. It is untrusted provider
// input held for the life of a provider session across up to
// MaxTrackedSlots slots.
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
const MaxFallbackReasonBytes = 1024

// Observation is one slot's KV-backend observation. Kind and FallbackReason
// live in ONE value because they are only meaningful together and must be
// written together: recording them in two maps lets a slot that degraded, then
// reloaded clean, keep a stale reason next to a fresh kind — a permanent false
// degrade, which is the exact failure this field exists to prevent.
type Observation struct {
	// Kind is the resolved backend, verbatim from the wire.
	Kind string
	// FallbackReason is the degrade reason, "" when the slot did not
	// degrade. Because the pair is always written together, "" here is an
	// OBSERVATION of no degrade, not missing data.
	FallbackReason string
}

// MaxTrackedSlots bounds the per-provider slot record. Slot models are
// untrusted provider input, so a box that heartbeats thousands of distinct slot
// models must not grow coordinator state without bound. A real box carries
// `maxModelSlots` (default 3) at a time and cycles through a handful more over
// a session, so the cap is unreachable in practice; past it, new models simply
// stay unattributed rather than being mis-attributed.
const MaxTrackedSlots = 64

// History is owned by one provider session. Its zero value is ready for use;
// callers serialize access with the provider lock.
type History struct {
	slots map[string]Observation
}

// Record folds the KV backend of every slot in a heartbeat into the history.
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
func (h *History) Record(bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	for i := range bc.Slots {
		slot := &bc.Slots[i]
		if slot.Model == "" || slot.KVBackend == nil {
			continue
		}
		if h.slots == nil {
			h.slots = make(map[string]Observation, len(bc.Slots))
		}
		if _, known := h.slots[slot.Model]; !known && len(h.slots) >= MaxTrackedSlots {
			continue
		}
		var reason string
		if slot.KVBackendFallbackReason != nil {
			reason = clampFallbackReason(*slot.KVBackendFallbackReason)
		}
		h.slots[slot.Model] = Observation{
			Kind:           *slot.KVBackend,
			FallbackReason: reason,
		}
	}
}

// clampFallbackReason bounds an untrusted reason to MaxFallbackReasonBytes.
// Truncation is from the tail, so the leading class token the metric groups on
// always survives.
//
// RUNE-SAFE. A plain reason[:n] byte slice can cut a multi-byte rune in half,
// and these reasons interpolate errors straight out of MLX/Metal — a
// non-ASCII path or device name is entirely possible. The trailing fragment
// would then be invalid UTF-8, which Postgres rejects on the route-outcome
// write and Go renders as U+FFFD in logs. Backing up to the last rune boundary
// costs at most three bytes of a 1 KiB tail.
func clampFallbackReason(reason string) string {
	if len(reason) <= MaxFallbackReasonBytes {
		return reason
	}
	cut := MaxFallbackReasonBytes
	for cut > 0 && !utf8.RuneStart(reason[cut]) {
		cut--
	}
	return reason[:cut]
}

// Observe reports the last observation for a model. False means no heartbeat
// named a backend; an observed empty Kind stays distinct from absence.
func (h *History) Observe(model string) (Observation, bool) {
	if h == nil {
		return Observation{}, false
	}
	obs, observed := h.slots[model]
	return obs, observed
}

// Forget invalidates attribution when a model is removed or its weights change.
func (h *History) Forget(model string) {
	if h != nil {
		delete(h.slots, model)
	}
}
