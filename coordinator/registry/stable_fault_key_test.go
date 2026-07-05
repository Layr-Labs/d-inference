package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Tests for the stable fault-key infrastructure: ALL fault-tracking state
// (inference-error cooldowns, node-health breaker, dispatch-load cooldowns,
// health ejection) keys by stable identity (serial → SE key → account,
// session id only when none exists), binds at attestation time, survives
// Disconnect, and re-attaches on reconnect. Regressions for the prod zombie
// exploit: reconnect churn (median 18 sessions/machine/week) wiped every
// session-keyed breaker before it could trip, letting 100%-error boxes absorb
// 2,800–13,300 requests each.

// attestSchedulerProvider registers a routable provider and completes its
// attestation through the REAL SetAttestationResult path, which binds the
// session id to the stable fault key (unlike setSchedulerProviderSerial's
// direct field write, used by tests that deliberately skip binding).
func attestSchedulerProvider(t *testing.T, reg *Registry, sessionID, model, serial string, decodeTPS float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, sessionID, model, decodeTPS)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: serial})
	return p
}

func faultKeyOf(r *Registry, sessionID string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.faultKeyLocked(sessionID)
}

// faultKeyLocked precedence: bound identity → disconnect cache → session id.
func TestFaultKeyBindingLifecycle(t *testing.T) {
	reg := New(testLogger())
	p := attestSchedulerProvider(t, reg, "sess-bind", "m", "SER-BIND", 50)

	if got := faultKeyOf(reg, "sess-bind"); got != "serial:SER-BIND" {
		t.Fatalf("bound session must resolve to its stable identity, got %q", got)
	}
	if got := faultKeyOf(reg, "sess-unknown"); got != "sess-unknown" {
		t.Fatalf("unbound session must fall back to itself, got %q", got)
	}

	// Re-attestation rebinds; clearing attestation unbinds (fail-open to
	// session keying, mirroring stableProviderIdentityLocked precedence).
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-2"})
	if got := faultKeyOf(reg, "sess-bind"); got != "sekey:PK-2" {
		t.Fatalf("re-attestation must rebind, got %q", got)
	}
	p.SetAttestationResult(nil)
	if got := faultKeyOf(reg, "sess-bind"); got != "sess-bind" {
		t.Fatalf("cleared attestation must unbind, got %q", got)
	}

	// After Disconnect the live binding is gone but the disconnect cache still
	// resolves the trailing ErrorCh-flush faults.
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-BIND"})
	reg.Disconnect("sess-bind")
	reg.mu.RLock()
	_, hasBinding := reg.faultKeyBySession["sess-bind"]
	reg.mu.RUnlock()
	if hasBinding {
		t.Fatal("Disconnect must remove the live session binding")
	}
	if got := faultKeyOf(reg, "sess-bind"); got != "serial:SER-BIND" {
		t.Fatalf("post-disconnect resolution must use the disconnect cache, got %q", got)
	}
}

// Codex P2: an attestation blob's serial/SE key are attacker-supplied until
// the signature VERIFIES, and SetAttestationResult runs before the Valid
// check. An INVALID result claiming a victim's serial must not bind — its
// faults stay session-keyed and never poison "serial:<victim>" — while a
// later VALID attestation binds (migrating the session-keyed state) and an
// invalid re-attestation after that unbinds back to session keying.
func TestInvalidAttestationDoesNotBindStableFaultKey(t *testing.T) {
	reg := New(testLogger())
	const model, victim = "spoof-model", "SER-VICTIM"

	p := makeSchedulerProvider(t, reg, "sess-evil", model, 100)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: false, SerialNumber: victim, PublicKey: "PK-EVIL"})

	if got := faultKeyOf(reg, "sess-evil"); got != "sess-evil" {
		t.Fatalf("invalid attestation must not bind; fault key = %q, want session fallback", got)
	}
	if got := reg.GetProviderStableIdentity("sess-evil"); got != "" {
		t.Fatalf("invalid attestation must yield no stable identity, got %q", got)
	}

	// Faults recorded now must land under the session key, never the victim's.
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome("sess-evil", false, 500, "internal error")
	}
	reg.mu.RLock()
	_, victimPoisoned := reg.providerOutcomes["serial:"+victim]
	_, sessionKeyed := reg.providerOutcomes["sess-evil"]
	reg.mu.RUnlock()
	if victimPoisoned {
		t.Fatal("faults from an invalid attestation poisoned the victim's serial-keyed state")
	}
	if !sessionKeyed {
		t.Fatal("faults must accumulate under the session fallback key")
	}

	// A subsequent VALID attestation binds normally and migrates the
	// session-keyed state to the (now-authenticated) identity.
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-REAL"})
	if got := faultKeyOf(reg, "sess-evil"); got != "serial:SER-REAL" {
		t.Fatalf("valid attestation must bind, got %q", got)
	}
	reg.mu.RLock()
	_, migrated := reg.providerOutcomes["serial:SER-REAL"]
	reg.mu.RUnlock()
	if !migrated {
		t.Fatal("session-keyed fault state must migrate on the first valid bind")
	}

	// An invalid re-attestation after a valid one unbinds (session keying).
	p.SetAttestationResult(&attestation.VerificationResult{Valid: false, SerialNumber: victim})
	if got := faultKeyOf(reg, "sess-evil"); got != "sess-evil" {
		t.Fatalf("invalid re-attestation must unbind, got %q", got)
	}
}

// Fault state must FOLLOW an identity rebind (Bugbot finding: sekey: →
// serial: enrichment orphaned accumulated state under the old key, letting a
// near-quarantine machine keep routing with a clean record on the same
// socket). Also covers the first-bind migration: strikes recorded BEFORE
// attestation live under the session-id fallback and must move to the stable
// key when the binding appears.
func TestFaultStateMigratesOnIdentityRebind(t *testing.T) {
	reg := New(testLogger())
	const model = "rebind-model"

	// Pre-attestation faults accumulate under the session-id fallback key.
	p := makeSchedulerProvider(t, reg, "sess-mig", model, 200)
	attestSchedulerProvider(t, reg, "healthy-mig", model, "SER-MIG-HEALTHY", 50)
	for i := 0; i < providerBreakerConsecTrip-2; i++ {
		if opened, _ := reg.RecordProviderOutcome("sess-mig", false, 500, "internal error"); opened {
			t.Fatalf("breaker opened early at fault %d", i+1)
		}
	}

	// First bind (SE key only): session-keyed state must migrate to sekey:.
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-MIG"})
	if opened, _ := reg.RecordProviderOutcome("sess-mig", false, 500, "internal error"); opened {
		t.Fatal("breaker must not trip yet — one fault short of the threshold")
	}

	// MDA enrichment rebinds sekey: → serial:. The accumulated count must
	// follow; the next fault is the trip.
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-MIG", SerialNumber: "SER-MIG"})
	if got := faultKeyOf(reg, "sess-mig"); got != "serial:SER-MIG" {
		t.Fatalf("enriched attestation must rebind to the serial key, got %q", got)
	}
	opened, _ := reg.RecordProviderOutcome("sess-mig", false, 500, "internal error")
	if !opened {
		t.Fatal("fault history must survive the identity rebind — the trip-threshold fault landed on a clean record")
	}
	if !reg.ProviderBreakerOpen("sess-mig") {
		t.Fatal("breaker must be open via the rebound identity")
	}

	// Old keys must not retain orphaned state.
	reg.mu.RLock()
	_, sekeyOrphan := reg.providerOutcomes["sekey:PK-MIG"]
	_, sessOrphan := reg.providerOutcomes["sess-mig"]
	reg.mu.RUnlock()
	if sekeyOrphan || sessOrphan {
		t.Fatalf("fault state orphaned under old keys (sekey=%v session=%v)", sekeyOrphan, sessOrphan)
	}
}

// REQUIRED regression: provider faults 4×, disconnects, reconnects with a NEW
// session id + the SAME serial, faults once more → the node-health breaker
// trips (the consecutive-fault count survived the reconnect). Fails without
// the stable keying: the old code deleted all breaker state on Disconnect.
func TestProviderBreakerSurvivesReconnect(t *testing.T) {
	reg := New(testLogger())
	const model, serial = "reconnect-model", "SER-ZOMBIE"

	// The zombie is faster (normally preferred); the healthy box exists so the
	// breaker gate has somewhere to divert to (with a lone provider the
	// fail-open valve would deliberately keep it routable).
	attestSchedulerProvider(t, reg, "sess-1", model, serial, 200)
	attestSchedulerProvider(t, reg, "healthy-sess", model, "SER-HEALTHY", 50)
	for i := 0; i < providerBreakerConsecTrip-1; i++ {
		if opened, _ := reg.RecordProviderOutcome("sess-1", false, 500, "internal error"); opened {
			t.Fatalf("breaker opened early at fault %d", i+1)
		}
	}
	reg.Disconnect("sess-1")

	attestSchedulerProvider(t, reg, "sess-2", model, serial, 200)
	opened, _ := reg.RecordProviderOutcome("sess-2", false, 500, "internal error")
	if !opened {
		t.Fatal("the first fault after reconnect must trip the breaker — fault state was wiped by the reconnect")
	}
	if !reg.ProviderBreakerOpen("sess-2") {
		t.Fatal("breaker must report open via the new session id")
	}
	// The routing hot path must divert to the healthy box.
	selected, _ := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "r", Model: model, RequestedMaxTokens: 64})
	if selected == nil {
		t.Fatal("healthy provider must still be selectable")
	}
	selected.RemovePending("r")
	if selected.ID == "sess-2" {
		t.Fatal("routing selected the breaker-open reconnected session")
	}
}

// The shape-keyed inference-error cooldown must accumulate strikes across a
// reconnect and gate the new session id.
func TestInferenceErrorCooldownSurvivesReconnect(t *testing.T) {
	reg := New(testLogger())
	const model, serial = "iec-model", "SER-IEC"

	attestSchedulerProvider(t, reg, "sess-1", model, serial, 100)
	if reg.RecordInferenceError("sess-1", model, 500, "base") {
		t.Fatal("one strike must not trip")
	}
	reg.Disconnect("sess-1")

	attestSchedulerProvider(t, reg, "sess-2", model, serial, 100)
	if !reg.RecordInferenceError("sess-2", model, 500, "base") {
		t.Fatal("the second strike after reconnect must trip — strikes were wiped by the reconnect")
	}
	if !reg.InferenceErrorCooldownActive("sess-2", model, "base") {
		t.Fatal("cooldown must be active via the new session id")
	}
	// A success through the new session clears the identity-keyed state.
	reg.RecordInferenceSuccess("sess-2", model, "base")
	if reg.InferenceErrorCooldownActive("sess-2", model, "base") {
		t.Fatal("success must clear the identity-keyed cooldown")
	}
}

// The dispatch-load cooldown must survive a reconnect within its TTL.
func TestDispatchLoadCooldownSurvivesReconnect(t *testing.T) {
	reg := New(testLogger())
	const model, serial = "dlc-model", "SER-DLC"

	attestSchedulerProvider(t, reg, "sess-1", model, serial, 100)
	reg.RecordDispatchLoadFailure("sess-1", model)
	reg.Disconnect("sess-1")

	attestSchedulerProvider(t, reg, "sess-2", model, serial, 100)
	if !cooldownActive(reg, "sess-2", model, time.Now()) {
		t.Fatal("dispatch-load cooldown must survive the reconnect and gate the new session")
	}
	// A served request through the new session still lifts it early.
	reg.ClearDispatchLoadCooldown("sess-2", model)
	if cooldownActive(reg, "sess-2", model, time.Now()) {
		t.Fatal("ClearDispatchLoadCooldown must clear the identity-keyed entry")
	}
}

// REQUIRED regression for the prod black hole (provider f21d71d7: 13,333
// capacity-shaped 503s, 100% error rate, 90 min, never ejected): a provider
// failing EVERY request with the incident's 503 shape must stop being
// selectable within ~10 failures — even while reconnecting between failures —
// and the healthy provider must keep serving throughout.
func TestBlackHoleStopsReceivingTrafficWithinTenFailures(t *testing.T) {
	reg := New(testLogger())
	const model = "blackhole-model"
	const rejectStr = "token_budget_exhausted: request exceeds active token budget"

	// The black hole is faster, so the cost scheduler prefers it until gated.
	attestSchedulerProvider(t, reg, "bh-sess-1", model, "SER-BH", 200)
	attestSchedulerProvider(t, reg, "healthy-sess", model, "SER-OK", 50)

	badPicks, session := 0, 1
	served := false
	for attempt := 0; attempt < 40; attempt++ {
		rid := fmt.Sprintf("r-%d", attempt)
		selected, _ := reg.ReserveProviderEx(model, &PendingRequest{RequestID: rid, Model: model, RequestedMaxTokens: 64})
		if selected == nil {
			t.Fatalf("attempt %d: no provider selectable", attempt)
		}
		sid := reg.GetProviderStableIdentity(selected.ID)
		selected.RemovePending(rid)
		if sid == "serial:SER-BH" {
			badPicks++
			// The api glue on a provider error terminal: node breaker +
			// stable-identity ejection (capacity-shaped 503s are neutral to
			// the former, counted as a zero-success streak by the latter).
			reg.RecordProviderOutcome(selected.ID, false, 503, rejectStr)
			reg.RecordProviderServeOutcome(sid, false, 503, rejectStr)
			// The zombie signature: reconnect every few failures. Fault state
			// must keep accumulating across sessions.
			if badPicks%3 == 0 {
				reg.Disconnect(selected.ID)
				session++
				attestSchedulerProvider(t, reg, fmt.Sprintf("bh-sess-%d", session), model, "SER-BH", 200)
			}
			continue
		}
		// Healthy box serves cleanly.
		reg.RecordProviderOutcome(selected.ID, true, 200, "")
		reg.RecordProviderServeOutcome(sid, true, 200, "")
		served = true
	}
	if badPicks > healthEjectionCapacityConsecTrip {
		t.Fatalf("black hole absorbed %d requests before ejection, want <= %d", badPicks, healthEjectionCapacityConsecTrip)
	}
	if !reg.HealthEjectionOpen("serial:SER-BH") {
		t.Fatal("black hole must be health-ejected")
	}
	if !served {
		t.Fatal("healthy provider never served — ejection must not zero out routing")
	}
}

// Disconnect must keep identity-keyed fault state and only clean per-session
// state (pending loads, the session binding); a provider with NO stable
// identity still has its session-keyed residue dropped.
func TestDisconnectKeepsStableFaultStateCleansSessionState(t *testing.T) {
	reg := New(testLogger())
	const model, serial = "keep-model", "SER-KEEP"
	attestSchedulerProvider(t, reg, "sess-1", model, serial, 100)

	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome("sess-1", false, 500, "internal error")
	}
	reg.RecordInferenceError("sess-1", model, 500, "base")
	reg.RecordDispatchLoadFailure("sess-1", model)
	reg.mu.Lock()
	reg.pendingModelLoads["sess-1:"+model] = time.Now().Add(time.Minute)
	reg.pendingModelLoadStarted["sess-1:"+model] = time.Now()
	reg.mu.Unlock()

	reg.Disconnect("sess-1")

	stableKey := "serial:" + serial
	reg.mu.RLock()
	_, hasWin := reg.providerOutcomes[stableKey]
	_, hasOpen := reg.providerBreakerOpenUntil[stableKey]
	_, hasStrikes := reg.inferenceErrorStrikes[inferenceErrorKey{ProviderID: stableKey, ModelID: model, Shape: "base"}]
	_, hasDLC := reg.dispatchLoadCooldowns[stableKey+":"+model]
	_, hasPending := reg.pendingModelLoads["sess-1:"+model]
	_, hasBinding := reg.faultKeyBySession["sess-1"]
	reg.mu.RUnlock()
	if !hasWin || !hasOpen || !hasStrikes || !hasDLC {
		t.Fatalf("identity-keyed fault state must survive Disconnect: win=%v open=%v strikes=%v dlc=%v",
			hasWin, hasOpen, hasStrikes, hasDLC)
	}
	if hasPending {
		t.Fatal("per-session pending model loads must be cleaned on Disconnect")
	}
	if hasBinding {
		t.Fatal("the session fault-key binding must be removed on Disconnect")
	}

	// No stable identity → the fault key WAS the session id → residue dropped.
	makeSchedulerProvider(t, reg, "sess-anon", model, 100)
	reg.RecordProviderOutcome("sess-anon", false, 500, "internal error")
	reg.RecordInferenceError("sess-anon", model, 500, "base")
	reg.RecordDispatchLoadFailure("sess-anon", model)
	reg.Disconnect("sess-anon")
	reg.mu.RLock()
	_, anonWin := reg.providerOutcomes["sess-anon"]
	_, anonStrikes := reg.inferenceErrorStrikes[inferenceErrorKey{ProviderID: "sess-anon", ModelID: model, Shape: "base"}]
	_, anonDLC := reg.dispatchLoadCooldowns["sess-anon:"+model]
	reg.mu.RUnlock()
	if anonWin || anonStrikes || anonDLC {
		t.Fatalf("session-keyed residue of an identity-less provider must be dropped: win=%v strikes=%v dlc=%v",
			anonWin, anonStrikes, anonDLC)
	}
}

// REQUIRED: stale identities expire — the capacity-streak map is bounded by
// the health-ejection sweep once it grows past its cap.
func TestHealthEjectionCapacityStreakSweep(t *testing.T) {
	reg := New(testLogger())
	const rejectStr = "token_budget_exhausted: request exceeds active token budget"
	for i := 0; i < 2100; i++ {
		reg.RecordProviderServeOutcome(fmt.Sprintf("serial:churned-%d", i), false, 503, rejectStr)
	}
	reg.mu.Lock()
	for id, s := range reg.healthEjectionCapacityStreaks {
		s.last = s.last.Add(-(healthEjectionWindow + time.Second))
		reg.healthEjectionCapacityStreaks[id] = s
	}
	size := len(reg.healthEjectionCapacityStreaks)
	reg.mu.Unlock()
	if size < 2050 {
		t.Fatalf("setup produced too few streak entries: %d", size)
	}

	// The next record sweeps the stale identities before recording.
	reg.RecordProviderServeOutcome("serial:live", false, 503, rejectStr)

	reg.mu.RLock()
	after := len(reg.healthEjectionCapacityStreaks)
	reg.mu.RUnlock()
	if after != 1 {
		t.Fatalf("sweep must drop every stale identity, leaving only the live one; got %d", after)
	}
}

// A stale capacity streak (older than the window) must not combine with a
// fresh blip: 9 old strikes + 1 fresh one is NOT a black hole.
func TestHealthEjectionCapacityStreakStaleReset(t *testing.T) {
	reg := New(testLogger())
	const sid = "serial:STALE"
	const rejectStr = "token_budget_exhausted: request exceeds active token budget"
	for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
		reg.RecordProviderServeOutcome(sid, false, 503, rejectStr)
	}
	reg.mu.Lock()
	s := reg.healthEjectionCapacityStreaks[sid]
	s.last = s.last.Add(-(healthEjectionWindow + time.Second))
	reg.healthEjectionCapacityStreaks[sid] = s
	reg.mu.Unlock()

	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, rejectStr); ejected {
		t.Fatal("a fresh strike after a stale streak must restart the count, not eject")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("identity must not be ejected off a stale streak")
	}
}

// The node-capacity-strike classifier: capacity-shaped 5xx count, request-shape
// context overflows and client/fault shapes do not.
func TestIsNodeCapacityRejectStrike(t *testing.T) {
	cases := []struct {
		code int
		err  string
		want bool
	}{
		{503, "token_budget_exhausted: request exceeds active token budget", true},
		{503, "token_budget_exhausted: insufficient global KV cache headroom", true},
		{503, "request queue full", true},
		{503, "server busy", true},
		{500, "token_budget_exhausted", true},
		{502, "insufficient KV headroom", true},
		{504, "request timed out waiting for capacity", true},
		// Request-shape context overflows indict the request, not the node.
		{503, "token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)", false},
		{503, "context length exceeded", false},
		{503, "prompt too long for context window", false},
		// Faults are owned by the fault path, client shapes are neutral.
		{503, "internal error", false},
		{500, "panic: index out of range", false},
		{400, "token budget", false},
		{429, "queue full", false},
	}
	for _, c := range cases {
		if got := isNodeCapacityRejectStrike(c.code, c.err); got != c.want {
			t.Errorf("isNodeCapacityRejectStrike(%d, %q)=%v, want %v", c.code, c.err, got, c.want)
		}
	}
}
