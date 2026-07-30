package api

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Per-backend request instrumentation for the v0.8.0 paged-KV rollout
// (migration plan §16.1, Gate G5).
//
// With no canary fleet, per-backend segmentation is the only way to tell a
// paged regression from ordinary fleet noise. Three families are needed:
//
//   - error / 503 rate — d_inference.inference.request_outcome already carried
//     the OR-uptime class per request; it now also carries kv_backend, so the
//     numerator AND the denominator segment together (see or_uptime.go).
//   - TTFT — the measured dispatch→first-content latency existed only as the
//     PERSISTED inference_routes.actual_ttft_ms column and the X-Timing
//     response header. Neither is groupable on a live dashboard, and the one
//     TTFT histogram in the coordinator (routing.cache_selection_ttft_ms) only
//     fires for cache-routing-participating requests. So the value is now also
//     emitted as d_inference.inference.ttft_ms.
//   - decode TPS — same story: outcome.ActualDecodeTPS was computed in
//     handleComplete and written only to Postgres. Now also
//     d_inference.inference.decode_tps.
//
// Neither histogram introduces a new MEASUREMENT: both take the value
// handleComplete already computed for the route-outcome row, at the same
// instant, so the metric and the persisted column cannot disagree.
const (
	// metricRequestTTFT is the delivered-content TTFT (dispatch → first content
	// chunk) in milliseconds — the same quantity persisted as actual_ttft_ms.
	// Tags: model, kv_backend.
	metricRequestTTFT = "inference.ttft_ms"
	// metricRequestDecodeTPS is the measured decode throughput (completion
	// tokens over the first-chunk → completion window) — the same quantity
	// persisted as actual_decode_tps. Tags: model, kv_backend.
	metricRequestDecodeTPS = "inference.decode_tps"
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

// kvBackendAttribution is the pair of KV-backend dimensions a request is tagged
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
type kvBackendAttribution struct {
	Backend  string
	Fallback string
}

// newUnknownKVBackendAttribution is the honest "no serving slot" pair: unknown
// on both dimensions, never a real backend and never `none`.
func newUnknownKVBackendAttribution() kvBackendAttribution {
	backend, fallback := registry.UnknownKVBackendTags()
	return kvBackendAttribution{Backend: backend, Fallback: fallback}
}

// appendTags renders the pair onto dst. Callers pass a slice preallocated for
// their own tags plus these two, so a request outcome costs one allocation
// rather than a fresh 2-element slice plus an append-grow per call site.
func (a kvBackendAttribution) appendTags(dst []string) []string {
	return append(dst, kvBackendTagKey+a.Backend, kvBackendFallbackTagKey+a.Fallback)
}

// kvBackendAttribution resolves both metric dimensions for the SLOT (provider +
// concrete build id) that served a request. Provider granularity would be
// wrong: one box can hold up to maxModelSlots models and may serve paged for
// one and contiguous for another during a staged rollout.
//
// Returns the unknown pair when no slot observation exists — never a backend
// kind, and never `none`. Coercing an absent value to "contiguous"/"none" would
// make the rollout dashboard show a clean baseline composed entirely of
// pre-0.8.0 providers.
func (s *Server) kvBackendAttribution(providerID, model string) kvBackendAttribution {
	if s == nil || s.registry == nil {
		return newUnknownKVBackendAttribution()
	}
	backend, fallback := s.registry.SlotKVBackendTags(providerID, model)
	return kvBackendAttribution{Backend: backend, Fallback: fallback}
}

// providerKVBackendAttribution is the same resolution for a caller that ALREADY
// holds the provider. The WebSocket read loop does: taking providerID back out
// of it only to have the registry look the provider up again costs a second
// registry read-lock on the hot per-request completion path.
func (s *Server) providerKVBackendAttribution(p *registry.Provider, model string) kvBackendAttribution {
	if s == nil || p == nil {
		return newUnknownKVBackendAttribution()
	}
	backend, fallback := p.SlotKVBackendTags(model)
	return kvBackendAttribution{Backend: backend, Fallback: fallback}
}

// emitRequestBackendLatency records the per-request TTFT and decode-throughput
// histograms, segmented by the serving slot's KV backend. Both values come from
// the completed route outcome; a non-finite or non-positive value means "not
// measurable for this request" and is skipped rather than recorded as a zero
// sample, which would drag a percentile toward the floor.
//
// Both guards run BEFORE the tags are built: ddHistogram checks s.dd only after
// its arguments exist, so an unconfigured Datadog (every test, every dev
// coordinator) would otherwise pay the tag construction on every completion.
func (s *Server) emitRequestBackendLatency(model string, attr kvBackendAttribution, ttftMs, decodeTPS float64) {
	if s == nil || s.dd == nil {
		return
	}
	ttftUsable := usableMetricSample(ttftMs)
	decodeUsable := usableMetricSample(decodeTPS)
	if !ttftUsable && !decodeUsable {
		return
	}
	tags := attr.appendTags(append(make([]string, 0, 3), "model:"+model))
	if ttftUsable {
		s.ddHistogram(metricRequestTTFT, ttftMs, tags)
	}
	if decodeUsable {
		s.ddHistogram(metricRequestDecodeTPS, decodeTPS, tags)
	}
}

func usableMetricSample(v float64) bool {
	return v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0)
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
func (d *dispatchState) noteServingSlot() {
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
// EXCEPTION — a latched deterministic verdict freezes the latch. Once
// shouldStopFailover/latchDeterministicLoser has latched d.unservable or
// d.terminalClientError, the terminal response IS that verdict (the 4xx/422/
// 429 of the slot that produced it), regardless of what a still-racing backup
// does next. Re-latching to the backup would book the PRIMARY's controlling
// 4xx under the backup's backend. latchTerminalAttribution pins the latch to
// the verdict slot at the moment the verdict latches; this guard keeps it
// there. A backup that goes on to WIN is unaffected: commit-path reads go
// through the live d.pr (see kvBackendAttribution), not this latch.
func (d *dispatchState) noteServingSlotFor(pr *registry.PendingRequest) {
	if pr == nil || pr.ProviderID == "" {
		return
	}
	if d.attributionLatchFrozen() {
		return
	}
	d.servedKVBackend = d.s.kvBackendAttribution(pr.ProviderID, pr.Model)
	d.servedKVProviderID, d.servedKVModel = pr.ProviderID, pr.Model
}

// attributionLatchFrozen reports whether a deterministic terminal verdict has
// latched — from that point the outcome attribution belongs to the slot whose
// verdict controls the terminal response, and must not follow later racers.
func (d *dispatchState) attributionLatchFrozen() bool {
	return d.unservable || d.terminalClientError
}

// latchTerminalAttribution pins the outcome attribution to the provider whose
// deterministic verdict just latched (latchDeterministicLoser). It is the
// pinning act itself, so it bypasses the freeze guard — and must run at the
// SAME site that latches the verdict, before any backup re-latch can race it.
func (d *dispatchState) latchTerminalAttribution(provider *registry.Provider) {
	if provider == nil || provider.ID == "" {
		return
	}
	d.servedKVBackend = d.s.providerKVBackendAttribution(provider, d.model)
	d.servedKVProviderID, d.servedKVModel = provider.ID, d.model
}

// kvBackendAttribution is the KV-backend metric pair for this dispatch. It
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
func (d *dispatchState) kvBackendAttribution() kvBackendAttribution {
	if pr := d.pr; pr != nil && pr.ProviderID != "" {
		if pr.ProviderID == d.servedKVProviderID && pr.Model == d.servedKVModel {
			return d.servedKVBackend
		}
		att := d.s.kvBackendAttribution(pr.ProviderID, pr.Model)
		if !d.attributionLatchFrozen() {
			d.servedKVBackend = att
			d.servedKVProviderID, d.servedKVModel = pr.ProviderID, pr.Model
		}
		return att
	}
	if d.servedKVProviderID == "" {
		// Never latched: no attempt ever reached a slot.
		return newUnknownKVBackendAttribution()
	}
	return d.servedKVBackend
}
