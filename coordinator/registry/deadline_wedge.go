package registry

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Deadline-wedge skip — the NARROW form (utilization research §5, README
// item 3).
//
// deadline_unreachable is health-neutral by design: the dispatch loop nils
// the provider before any breaker, capacity-rate window or budget clamp sees
// the refusal, shouldStopFailover returns false without a counter, and the
// refuser is excluded per request only. A deadline-wedged slot (a provider
// whose engine keeps refusing the remaining first-content budget while its
// heartbeat reports an idle slot and a healthy decode EWMA — the cold-start
// projection wedge T2-01 fixes provider-side) therefore ranks FIRST for the
// next request too: in prod one session took 28.6% of a model's attempt-0
// dispatches over 3 h and served 0, and four 9-57 tok/s slots absorbed
// 137,546 attempt-0 dispatches/day at 99.2% refusal. The provider-computed
// wedge_suspected bit cannot see this (it needs admits; refusals never
// admit).
//
// DISCRIMINATOR. A refusal counts ONLY when it can indict the slot: the
// request was SHORT (prompt < deadlineWedgeMaxPromptTokens), was dispatched
// onto an EMPTY slot (zero coordinator occupancy at reservation: no pending
// for the provider, nothing running or waiting per its heartbeat), was the
// PRIMARY attempt (Attempt == 0 — a retry lands with a clock already shrunk
// by the refuser's round trip, so a healthy second choice refusing it says
// nothing), and carried a first-content budget the coordinator had consumed
// at most deadlineWedgeMaxCoordinatorLag of before dispatch (queue wait or
// a Registry.mu writer-wait episode eats the clock; a slot refusing what is
// left is the coordinator's latency, not a wedge). The baseline refusal
// rate there is 0.5-3.5%, so deadlineWedgeThreshold consecutive such
// refusals with no accept in between is the wedge signature; a busy box
// legitimately refusing long prompts is never counted. The research numbers
// behind the feature are all attempt-0 dispatches with full clocks, so the
// narrowing loses no target signal. This must never grow into a
// refusal-rate derater: refusal rate is a lagging load signal active on 93%
// of gpt-oss provider×5-min cells.
//
// SHAPE. Mirrors capacity_cooldown.go: per (stable fault key, model) pair,
// a run counter and a skip entry {until, trips, probeAt}; a trip quarantines
// the pair for deadlineWedgeBaseTTL × 2^trips capped at deadlineWedgeMaxTTL;
// after expiry exactly ONE request passes as the half-open probe (claimed at
// reservation commit); any accept (first content or clean completion) clears
// everything. TTL ≤ 120 s because the wedge lives in one EngineV2Bridge and
// dies on process restart — a healthy restarted slot must not be quarantined
// long — and it is keyed by the stable fault key so a reconnect cannot reset
// a run (migrated on rebind; session-keyed residue dropped on Disconnect).
//
// LOCKING. A LEAF mutex of its own, lazily created; it never takes r.mu or
// p.mu (the completion_calibration idiom). The routing gate reads it with
// r.mu and p.mu held (order r.mu → p.mu → wedge.mu); the api hook resolves
// the fault key under r.mu.RLock, releases, then records.
//
// SWITCH. EIGENINFERENCE_DEADLINE_WEDGE_SKIP (read once at construction):
// off (default) = shadow — refusals are recorded, would-be skips counted
// (DeadlineWedgeStats) and nothing is gated, so routing is byte-identical;
// on = the gate skips armed pairs. INTERIM until T2-01 reaches the fleet.
const (
	envDeadlineWedgeSkip = "EIGENINFERENCE_DEADLINE_WEDGE_SKIP"

	// deadlineWedgeThreshold is the number of consecutive short-prompt,
	// empty-slot deadline refusals (no accept in between) that arm a skip.
	deadlineWedgeThreshold = 5
	// deadlineWedgeMaxPromptTokens: refusals of prompts at or above this
	// are never counted (a long prompt can legitimately miss the deadline).
	deadlineWedgeMaxPromptTokens = 2_048
	// deadlineWedgeMaxCoordinatorLag is the most of the request-absolute
	// first-content clock the coordinator may have consumed before dispatch
	// (ingress → the budget attached to the attempt) for the refusal to
	// count: normal routing costs milliseconds, while queue wait and
	// Registry.mu writer waits (0.5-2.5 s in the 2026-08-31 regime) leave a
	// budget a healthy slot can legitimately refuse.
	deadlineWedgeMaxCoordinatorLag = time.Second
	// deadlineWedgeBaseTTL / MaxTTL bound the quarantine: base 120 s (the
	// research ceiling), doubling per re-trip, capped at 10 min.
	deadlineWedgeBaseTTL = 120 * time.Second
	deadlineWedgeMaxTTL  = 10 * time.Minute
	// deadlineWedgeProbeWindow is how long a claimed half-open probe keeps
	// the gate closed to everyone else while its outcome is pending; a probe
	// that dies before any terminal cannot wedge the pair closed.
	deadlineWedgeProbeWindow = 30 * time.Second
	// deadlineWedgeRunTTL bounds how long a partial run stays live: runs
	// older than this restart instead of combining with fresh refusals.
	deadlineWedgeRunTTL = 5 * time.Minute
)

// deadlineWedgeKey identifies a (stable fault key, model) pair.
type deadlineWedgeKey struct {
	FaultKey string
	ModelID  string
}

type deadlineWedgeRun struct {
	n    int
	last time.Time
}

type deadlineWedgeSkip struct {
	until   time.Time
	trips   int // arms so far (1 after the first trip); the re-arm TTL is base × 2^trips
	probeAt time.Time
}

// DeadlineWedgeEvent names what a recorded refusal did, for the
// routing.deadline_wedge_skip{event} series.
type DeadlineWedgeEvent string

const (
	DeadlineWedgeIgnored DeadlineWedgeEvent = "ignored" // not short, not on an empty slot
	DeadlineWedgeRun     DeadlineWedgeEvent = "run"     // counted toward the threshold
	DeadlineWedgeArmed   DeadlineWedgeEvent = "armed"   // threshold reached: pair skipped (or would be, in shadow)
	DeadlineWedgeRearmed DeadlineWedgeEvent = "rearmed" // half-open probe refused: doubled TTL
)

// DeadlineWedgeStats is the observability snapshot.
type DeadlineWedgeStats struct {
	// Enabled reports the switch (false = shadow).
	Enabled bool
	// ArmedPairs is the number of pairs currently inside a skip TTL.
	ArmedPairs int
	// Skips counts routing-gate skips of armed pairs (cumulative; only
	// increments with the switch on). ShadowSkips counts the skips the gate
	// WOULD have made with the switch off (cumulative).
	Skips, ShadowSkips int64
	// Probes counts half-open probes claimed; Cleared counts pairs cleared
	// by an accept (cumulative).
	Probes, Cleared int64
}

// deadlineWedgeTracker holds the wedge state behind its own leaf mutex.
type deadlineWedgeTracker struct {
	// enabled is the switch; atomic so the gate (under r.mu) and a live flip
	// (tests) never race, and the gate reads it without the leaf lock.
	enabled atomic.Bool
	mu      sync.Mutex
	runs    map[deadlineWedgeKey]deadlineWedgeRun
	skips   map[deadlineWedgeKey]*deadlineWedgeSkip

	skipCount, shadowSkipCount, probeCount, clearCount atomic.Int64
}

func newDeadlineWedgeTracker(enabled bool) *deadlineWedgeTracker {
	w := &deadlineWedgeTracker{
		runs:  make(map[deadlineWedgeKey]deadlineWedgeRun),
		skips: make(map[deadlineWedgeKey]*deadlineWedgeSkip),
	}
	w.enabled.Store(enabled)
	return w
}

func loadDeadlineWedgeSkipEnabled() bool {
	return env.EnvBool(envDeadlineWedgeSkip, false)
}

// note records one deadline refusal outcome for the pair. indicts reports
// whether the refused dispatch satisfies every discriminator
// (deadlineRefusalIndictsSlot). Returns the event.
func (w *deadlineWedgeTracker) note(key deadlineWedgeKey, indicts bool, now time.Time) DeadlineWedgeEvent {
	if !indicts {
		return DeadlineWedgeIgnored
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.sweepLocked(now)

	// An armed pair whose TTL lapsed and whose probe just refused re-arms
	// with the doubled TTL (the half-open re-probe failed).
	if s, ok := w.skips[key]; ok {
		if now.Before(s.until) {
			return DeadlineWedgeRun // straggler inside the TTL: never extends it
		}
		s.until = now.Add(deadlineWedgeBackoff(s.trips))
		s.trips++
		s.probeAt = time.Time{}
		delete(w.runs, key)
		return DeadlineWedgeRearmed
	}

	run := w.runs[key]
	if run.n > 0 && now.Sub(run.last) > deadlineWedgeRunTTL {
		run.n = 0
	}
	run.n++
	run.last = now
	if run.n < deadlineWedgeThreshold {
		w.runs[key] = run
		return DeadlineWedgeRun
	}
	delete(w.runs, key)
	// trips counts arms so far: the first arm uses the base TTL, each
	// half-open re-arm doubles it (deadlineWedgeBackoff(trips)).
	w.skips[key] = &deadlineWedgeSkip{until: now.Add(deadlineWedgeBaseTTL), trips: 1}
	return DeadlineWedgeArmed
}

// clear drops the pair's run and skip: an accept proves the slot serves.
func (w *deadlineWedgeTracker) clear(key deadlineWedgeKey) {
	w.mu.Lock()
	_, hadRun := w.runs[key]
	_, hadSkip := w.skips[key]
	delete(w.runs, key)
	delete(w.skips, key)
	w.mu.Unlock()
	if hadRun || hadSkip {
		w.clearCount.Add(1)
	}
}

// skipLocked reports whether routing should skip the pair (mirrors
// capacityCooldownActiveLocked's half-open semantics) and counts the verdict:
// with the switch on the gate skips, with it off the would-be skip is only
// counted. Callers hold r.mu (either mode); this takes the leaf lock.
func (w *deadlineWedgeTracker) shouldSkip(key deadlineWedgeKey, now time.Time) bool {
	w.mu.Lock()
	s, ok := w.skips[key]
	active := ok && (now.Before(s.until) ||
		(!s.probeAt.IsZero() && now.Before(s.probeAt.Add(deadlineWedgeProbeWindow))))
	w.mu.Unlock()
	if !active {
		return false
	}
	if w.enabled.Load() {
		w.skipCount.Add(1)
		return true
	}
	w.shadowSkipCount.Add(1)
	return false
}

// claimProbe claims the single half-open probe for an expired skip at
// reservation commit (caller holds r.mu for writing, so claims serialize).
func (w *deadlineWedgeTracker) claimProbe(key deadlineWedgeKey, now time.Time) {
	w.mu.Lock()
	defer w.mu.Unlock()
	s, ok := w.skips[key]
	if !ok || now.Before(s.until) {
		return
	}
	if s.probeAt.IsZero() || !now.Before(s.probeAt.Add(deadlineWedgeProbeWindow)) {
		s.probeAt = now
		w.probeCount.Add(1)
	}
}

// migrate re-keys the pair state from one fault key to another (identity
// rebind); the fresher / larger state wins where both exist.
func (w *deadlineWedgeTracker) migrate(oldKey, newKey string) {
	if oldKey == "" || newKey == "" || oldKey == newKey {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for k, run := range w.runs {
		if k.FaultKey != oldKey {
			continue
		}
		nk := deadlineWedgeKey{FaultKey: newKey, ModelID: k.ModelID}
		if cur, ok := w.runs[nk]; !ok || run.n > cur.n {
			w.runs[nk] = run
		}
		delete(w.runs, k)
	}
	for k, s := range w.skips {
		if k.FaultKey != oldKey {
			continue
		}
		nk := deadlineWedgeKey{FaultKey: newKey, ModelID: k.ModelID}
		if cur, ok := w.skips[nk]; !ok || s.until.After(cur.until) {
			w.skips[nk] = s
		}
		delete(w.skips, k)
	}
}

// forget drops every entry under a fault key (a disconnected session that
// never had a stable identity: its key never recurs).
func (w *deadlineWedgeTracker) forget(faultKey string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for k := range w.runs {
		if k.FaultKey == faultKey {
			delete(w.runs, k)
		}
	}
	for k := range w.skips {
		if k.FaultKey == faultKey {
			delete(w.skips, k)
		}
	}
}

// sweepLocked bounds the maps (session-keyed identities are never re-keyed).
func (w *deadlineWedgeTracker) sweepLocked(now time.Time) {
	if len(w.runs) > 1024 {
		for k, run := range w.runs {
			if now.Sub(run.last) > deadlineWedgeRunTTL {
				delete(w.runs, k)
			}
		}
	}
	if len(w.skips) > 1024 {
		for k, s := range w.skips {
			if !now.Before(s.until) && (s.probeAt.IsZero() || !now.Before(s.probeAt.Add(deadlineWedgeProbeWindow))) {
				delete(w.skips, k)
			}
		}
	}
}

func (w *deadlineWedgeTracker) stats(now time.Time) DeadlineWedgeStats {
	w.mu.Lock()
	armed := 0
	for _, s := range w.skips {
		if now.Before(s.until) {
			armed++
		}
	}
	w.mu.Unlock()
	return DeadlineWedgeStats{
		Enabled:     w.enabled.Load(),
		ArmedPairs:  armed,
		Skips:       w.skipCount.Load(),
		ShadowSkips: w.shadowSkipCount.Load(),
		Probes:      w.probeCount.Load(),
		Cleared:     w.clearCount.Load(),
	}
}

func deadlineWedgeBackoff(trips int) time.Duration {
	ttl := deadlineWedgeBaseTTL
	for i := 0; i < trips && ttl < deadlineWedgeMaxTTL; i++ {
		ttl *= 2
	}
	if ttl > deadlineWedgeMaxTTL {
		ttl = deadlineWedgeMaxTTL
	}
	return ttl
}

// ---- Registry surface ----

// NoteDeadlineRefusal records a provider-originated deadline_unreachable
// refusal of pr's dispatch onto providerID. pr is the refused attempt's
// pending request as the dispatch loop holds it after the terminal: its
// Attempt, ReserveOccupancy (stamped at reservation commit), estimated
// prompt and the first-content clock (Timing.ReceivedAt, FirstContentDeadline
// and the FirstContentBudgetMS attached at dispatch) are the discriminators
// (deadlineRefusalIndictsSlot). Called by the api layer from the dispatch
// loop's pre-content error funnel; speculative backups and the coordinator's
// own late-content conversions are excluded by the caller.
func (r *Registry) NoteDeadlineRefusal(providerID string, pr *PendingRequest) DeadlineWedgeEvent {
	if providerID == "" || pr == nil || pr.Model == "" {
		return DeadlineWedgeIgnored
	}
	r.mu.RLock()
	key := deadlineWedgeKey{FaultKey: r.faultKeyLocked(providerID), ModelID: pr.Model}
	r.mu.RUnlock()
	return r.deadlineWedge.note(key, deadlineRefusalIndictsSlot(pr), time.Now())
}

// deadlineRefusalIndictsSlot applies the DISCRIMINATOR (file comment): short
// prompt, empty slot, primary attempt, and a first-content clock of which
// the coordinator consumed at most deadlineWedgeMaxCoordinatorLag before the
// attempt was dispatched. A request without a clock (no ingress stamp or no
// deadline) or without an attached budget never indicts: the provider was
// not handed a budget it could refuse.
func deadlineRefusalIndictsSlot(pr *PendingRequest) bool {
	if pr.Attempt != 0 || pr.ReserveOccupancy != 0 || pr.EstimatedPromptTokens >= deadlineWedgeMaxPromptTokens {
		return false
	}
	if pr.Timing == nil || pr.Timing.ReceivedAt.IsZero() || pr.FirstContentDeadline.IsZero() || pr.FirstContentBudgetMS <= 0 {
		return false
	}
	clockMS := pr.FirstContentDeadline.Sub(pr.Timing.ReceivedAt).Milliseconds()
	consumedMS := clockMS - pr.FirstContentBudgetMS
	return consumedMS <= deadlineWedgeMaxCoordinatorLag.Milliseconds()
}

// DeadlineWedgeSkipActive reports whether the pair is currently skipped
// (with the switch on) — exposed for tests and observability.
func (r *Registry) DeadlineWedgeSkipActive(providerID, modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.deadlineWedgeSkipLocked(providerID, modelID, time.Now())
}

// deadlineWedgeSkipLocked is the routing-gate probe. Caller holds r.mu.
func (r *Registry) deadlineWedgeSkipLocked(providerID, modelID string, now time.Time) bool {
	return r.deadlineWedge.shouldSkip(deadlineWedgeKey{FaultKey: r.faultKeyLocked(providerID), ModelID: modelID}, now)
}

// claimDeadlineWedgeProbeLocked claims the pair's half-open probe at
// reservation commit. Caller holds r.mu for writing.
func (r *Registry) claimDeadlineWedgeProbeLocked(providerID, modelID string, now time.Time) {
	r.deadlineWedge.claimProbe(deadlineWedgeKey{FaultKey: r.faultKeyLocked(providerID), ModelID: modelID}, now)
}

// DeadlineWedgeStats returns the observability snapshot.
func (r *Registry) DeadlineWedgeStats() DeadlineWedgeStats {
	return r.deadlineWedge.stats(time.Now())
}

// SetDeadlineWedgeSkipEnabled flips the switch (tests; production reads the
// environment once at construction).
func (r *Registry) SetDeadlineWedgeSkipEnabled(enabled bool) {
	r.deadlineWedge.enabled.Store(enabled)
}
