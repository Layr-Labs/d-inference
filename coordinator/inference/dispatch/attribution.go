package dispatch

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// kvBackendTagKey is the resolved-kind tag name. Deliberately the same key and
// the same vocabulary as BackendSlotCapacity.kv_backend on the heartbeat wire
// and `kv_backend` in the telemetry-event allowlist, so per-slot capacity,
// telemetry events and request metrics all group identically.
const kvBackendTagKey = "kv_backend:"

// kvBackendFallbackTagKey is the degrade-class tag name, mirroring
// BackendSlotCapacity.kv_backend_fallback_reason. It is what makes a
// `kv_backend:contiguous` sample interpretable: without it, an operator who
// chose contiguous and a paged slot that fell back are the same point on the
// dashboard. `.auto` resolves CONTIGUOUS as of v0.8.1, so the bulk of the
// fleet is now `kv_backend:contiguous` + `kv_backend_fallback:none` — and this
// dimension is what keeps that expected population separable from the boxes
// that asked for paged and could not get it (kernel preflight, physical
// capacity, ineligibility, pool construction) and from a
// DARKBLOOM_CBV2_PAGED_KV kill switch.
// `none` is a real value here, not a filler — see
// registry.KVBackendFallbackTag.
const kvBackendFallbackTagKey = "kv_backend_fallback:"

// KVBackendAttribution is the pair of KV-backend dimensions a request is tagged
// with. It exists as one value, resolved from one slot observation, because the
// two tags are only meaningful together: a `contiguous` paired with a stale
// `none` reads as a deliberate configuration and hides a regression.
//
// Both fields are ALWAYS a named vocabulary value, never "". There is exactly
// one producer — registry.KVBackendTag / KVBackendFallbackTag, every branch of
// which returns a constant — and exactly one way to build the "no serving slot"
// case, newUnknownKVBackendAttribution. Nothing here re-normalizes on the way
// out; an empty tag would mean a third producer appeared, and the fix belongs
// there, not in a defensive coalesce that hides it.
type KVBackendAttribution struct {
	Backend  string
	Fallback string
}

// dispatchSlotAttribution is one immutable provider/model/slot-backend
// observation. The ordinary serving latch and sticky terminal snapshots use
// the same shape so terminal precedence never needs parallel provider fields.
type dispatchSlotAttribution struct {
	providerID string
	model      string
	backend    KVBackendAttribution
}

// NewUnknownKVBackendAttribution is the honest "no serving slot" pair: unknown
// on both dimensions, never a real backend and never `none`.
func NewUnknownKVBackendAttribution() KVBackendAttribution {
	backend, fallback := registry.UnknownKVBackendTags()
	return KVBackendAttribution{Backend: backend, Fallback: fallback}
}

// appendTags renders the pair onto dst. Callers pass a slice preallocated for
// their own tags plus these two, so a request outcome costs one allocation
// rather than a fresh 2-element slice plus an append-grow per call site.
func (a KVBackendAttribution) AppendTags(dst []string) []string {
	return append(dst, kvBackendTagKey+a.Backend, kvBackendFallbackTagKey+a.Fallback)
}

// KVBackendAttribution resolves both metric dimensions for the SLOT (provider +
// concrete build id) that served a request. Provider granularity would be
// wrong: one box can hold up to maxModelSlots models and may serve paged for
// one and contiguous for another during a staged rollout.
//
// Returns the unknown pair when no slot observation exists — never a backend
// kind, and never `none`. Coercing an absent value to "contiguous"/"none" would
// make the rollout dashboard show a clean baseline composed entirely of
// pre-0.8.0 providers.
func (s *Controller) KVBackendAttribution(providerID, model string) KVBackendAttribution {
	if s == nil || s.deps.Registry() == nil {
		return NewUnknownKVBackendAttribution()
	}
	backend, fallback := s.deps.Registry().SlotKVBackendTags(providerID, model)
	return KVBackendAttribution{Backend: backend, Fallback: fallback}
}

// providerKVBackendAttribution is the same resolution for a caller that ALREADY
// holds the provider. The WebSocket read loop does: taking providerID back out
// of it only to have the registry look the provider up again costs a second
// registry read-lock on the hot per-request completion path.
func (s *Controller) ProviderKVBackendAttribution(p *registry.Provider, model string) KVBackendAttribution {
	if s == nil || p == nil {
		return NewUnknownKVBackendAttribution()
	}
	backend, fallback := p.SlotKVBackendTags(model)
	return KVBackendAttribution{Backend: backend, Fallback: fallback}
}

func (d *execution) providerSlotAttribution(
	provider *registry.Provider,
	model string,
) dispatchSlotAttribution {
	if provider == nil || provider.ID == "" {
		return dispatchSlotAttribution{
			model:   model,
			backend: NewUnknownKVBackendAttribution(),
		}
	}
	if d.servedKVSlot.providerID == provider.ID &&
		d.servedKVSlot.model == model {
		// Preserve the dispatch-time observation if the failing slot vanished
		// from a later heartbeat during teardown.
		return d.servedKVSlot
	}
	return dispatchSlotAttribution{
		providerID: provider.ID,
		model:      model,
		backend:    d.s.ProviderKVBackendAttribution(provider, model),
	}
}

// noteServingSlot latches the KV-backend attribution of the slot this attempt
// was actually dispatched to. Called once per attempt, at the single point both
// the direct and the queue-drain paths converge on a dispatched request.
//
// The latch exists because every failover path clears d.provider/d.pr before
// the exhaustion ladder runs, and the ladder is where a dispatched-but-failed
// request emits its OR-uptime outcome. Without it the 5xx/timeout population —
// the half of Gate G5 that catches a paged regression — would all land in
// kv_backend:unknown.
func (d *execution) noteServingSlot() {
	d.noteServingSlotFor(d.pr)
}

// noteServingSlotFor re-latches the attribution to an explicit pending request.
// The speculative race paths need this: the backup is dispatched by
// dispatchOneProvider (not the noteServingSlot choke point), so once the
// PRIMARY has failed and the backup becomes the racer of record — or wins the
// race outright — the latch must follow it. Otherwise a backup failure that
// turns terminal after the race helpers clear d.pr would book under the
// PRIMARY's kv_backend tag, misattributing exactly the 5xx/timeout population
// Gate G5 segments per backend in a mixed-backend fleet. The invariant the
// re-latch sites maintain: the latch always names the slot whose failure would
// be the terminal one — the last slot still racing.
//
// EXCEPTION — a latched terminal verdict freezes the ordinary latch. This
// includes deterministic client/unservable verdicts and a genuine fault
// snapshot. Re-latching to a later neutral racer would book the controlling
// terminal under the wrong backend. Genuine faults carry their own immutable
// dispatchSlotAttribution and may replace one another atomically. A backup that
// goes on to WIN is unaffected: commit-path reads go through the live d.pr (see
// kvBackendAttribution), not the terminal snapshot.
func (d *execution) noteServingSlotFor(pr *registry.PendingRequest) {
	if pr == nil || pr.ProviderID == "" {
		return
	}
	if d.attributionLatchFrozen() {
		return
	}
	d.servedKVSlot = dispatchSlotAttribution{
		providerID: pr.ProviderID,
		model:      pr.Model,
		backend:    d.s.KVBackendAttribution(pr.ProviderID, pr.Model),
	}
}

// attributionLatchFrozen reports whether a terminal verdict has latched — from
// that point the outcome attribution belongs to the controlling verdict and
// must not follow later neutral racers.
func (d *execution) attributionLatchFrozen() bool {
	return d.genuineFault != nil || d.unservable || d.terminalClientError
}

// latchTerminalAttribution pins the outcome attribution to the provider whose
// deterministic verdict just latched (latchDeterministicLoser). It is the
// pinning act itself, so it bypasses the freeze guard — and must run at the
// SAME site that latches the verdict, before any backup re-latch can race it.
func (d *execution) latchTerminalAttribution(provider *registry.Provider) {
	if provider == nil || provider.ID == "" {
		return
	}
	d.servedKVSlot = d.providerSlotAttribution(provider, d.model)
}

// KVBackendAttribution is the KV-backend metric pair for this dispatch. It
// prefers the LIVE pending request, so a speculative backup that wins the race
// is attributed to the backup's slot rather than the primary's, and falls back
// to the latch once a failover has cleared it. A dispatch that never reached a
// slot tags as unknown on both dimensions.
//
// The live case reuses the latch when it was taken for the SAME (provider,
// model), which is every ordinary request: noteServingSlot latches at dispatch
// and the success path reads it again at commit, so re-resolving would take a
// second registry read lock per request for a value that provably has not
// moved. A speculative backup shows up as a KEY MISMATCH, not as a stale
// latch, and still re-resolves — and SAVES the resolution: a mismatch means a
// promotion the latch has not caught up with (backup promoted via AcceptedCh
// or preamble outside the noteServingSlot choke point). The promoted slot can
// error or time out pre-content AFTER the wait path clears d.pr, and the
// exhaustion fallback must then name the promoted slot, not the cancelled
// primary's stale latch. noteServingSlotFor owns the freeze rule (a latched
// deterministic verdict pins the latch to the verdict slot), so a frozen
// latch survives this save while the live return value stays truthful.
func (d *execution) KVBackendAttribution() KVBackendAttribution {
	if pr := d.pr; pr != nil && pr.ProviderID != "" {
		if d.genuineFault != nil {
			// A sticky speculative loser must not contaminate a survivor that
			// produces content. Live content always names its own serving slot;
			// the terminal snapshot is consulted only after no live winner remains.
			return d.s.KVBackendAttribution(pr.ProviderID, pr.Model)
		}
		if pr.ProviderID == d.servedKVSlot.providerID &&
			pr.Model == d.servedKVSlot.model {
			return d.servedKVSlot.backend
		}
		att := d.s.KVBackendAttribution(pr.ProviderID, pr.Model)
		if !d.attributionLatchFrozen() {
			d.servedKVSlot = dispatchSlotAttribution{
				providerID: pr.ProviderID,
				model:      pr.Model,
				backend:    att,
			}
		}
		return att
	}
	if d.servedKVSlot.providerID == "" {
		// Never latched: no attempt ever reached a slot.
		return NewUnknownKVBackendAttribution()
	}
	return d.servedKVSlot.backend
}

// exhaustedKVBackendAttribution applies the same terminal precedence as the
// exhausted status resolver. A dominant sticky fault owns an immutable slot
// observation captured with that fault; every other terminal uses the ordinary
// serving latch. Keeping this decision beside the status-selected snapshot
// prevents final status and request-outcome attribution from naming different
// attempts.
func (d *execution) exhaustedKVBackendAttribution(
	failure dispatchTerminalFailure,
	stickyFault bool,
) KVBackendAttribution {
	if stickyFault {
		return failure.attribution.backend
	}
	return d.KVBackendAttribution()
}
