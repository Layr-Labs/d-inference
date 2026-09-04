package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Version-changed reconnect reset (version_reset.go), live-isolated on a real
// Registry: sessions register, bind a serial identity, die abruptly with work
// in flight (the flush the 2026-08-31 upgrade wave produced), and reconnect.

const versionResetSerial = "SER-UPGRADE"
const versionResetStable = "serial:" + versionResetSerial

// bindVersionedSession registers a session, stores its binary version, and
// binds it to the serial identity. versionFirst=true is the re-attestation
// order (version already stored when bindStableFaultKey runs); false is the
// registration order (attestation binds BEFORE the api stores the version,
// so Provider.SetVersion must run the check).
func bindVersionedSession(t *testing.T, r *Registry, id, version string, versionFirst bool) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
	p := r.Register(id, nil, msg)
	bind := func() {
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: versionResetSerial})
	}
	if versionFirst {
		p.SetVersion(version)
		bind()
	} else {
		bind()
		p.SetVersion(version)
	}
	return p
}

// dieAbruptlyWithFlush parks requests on the session, drops it without a close
// frame, and records the flush terminals the consumers feed: enough 502s to
// trip the inference-error cooldown (2), the node breaker (5), and the
// identity ejection (8) — roughly one upgraded box's worth in the incident.
func dieAbruptlyWithFlush(t *testing.T, r *Registry, id string) {
	t.Helper()
	p := r.GetProvider(id)
	if p == nil {
		t.Fatalf("provider %s not registered", id)
	}
	for i := 0; i < 3; i++ {
		p.AddPending(&PendingRequest{
			RequestID: fmt.Sprintf("%s-req-%d", id, i),
			Model:     "m",
			ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
		})
	}
	r.DisconnectWithReason(id, DisconnectReasonReadError)
	sid := r.GetProviderStableIdentity(id)
	if sid != versionResetStable {
		t.Fatalf("stable identity after disconnect = %q, want %q", sid, versionResetStable)
	}
	for i := 0; i < 2; i++ {
		r.RecordInferenceError(id, "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)
	}
	for i := 0; i < 5; i++ {
		r.RecordProviderOutcome(id, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
	for i := 0; i < 8; i++ {
		r.RecordProviderServeOutcome(sid, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
}

// assertIdentityQuarantine checks all three fault trackers for the identity,
// querying the inference-error cooldown and node breaker through queryID
// (a live session id resolves via faultKeyBySession, a dead one via the
// disconnect cache) and the ejection through the stable id.
func assertIdentityQuarantine(t *testing.T, r *Registry, queryID string, want bool) {
	t.Helper()
	if got := r.InferenceErrorCooldownActive(queryID, "m", "base"); got != want {
		t.Errorf("InferenceErrorCooldownActive(%s) = %v, want %v", queryID, got, want)
	}
	if got := r.ProviderBreakerOpen(queryID); got != want {
		t.Errorf("ProviderBreakerOpen(%s) = %v, want %v", queryID, got, want)
	}
	if got := r.HealthEjectionOpen(versionResetStable); got != want {
		t.Errorf("HealthEjectionOpen(%s) = %v, want %v", versionResetStable, got, want)
	}
}

func TestVersionChangedReconnect_ClearsDisconnectFlushStrikes(t *testing.T) {
	for _, versionFirst := range []bool{true, false} {
		name := "registration order (bind then SetVersion)"
		if versionFirst {
			name = "re-attestation order (SetVersion then bind)"
		}
		t.Run(name, func(t *testing.T) {
			r := New(testLogger())
			bindVersionedSession(t, r, "s1", "0.9.0", true)
			dieAbruptlyWithFlush(t, r, "s1")
			assertIdentityQuarantine(t, r, "s1", true)

			bindVersionedSession(t, r, "s2", "0.9.1", versionFirst)
			assertIdentityQuarantine(t, r, "s2", false)
			if r.InferenceErrorCooldownActive(versionResetStable, "m", "base") {
				t.Errorf("cooldown still active under the stable id after the version bump")
			}
		})
	}
}

func TestSameVersionReconnect_RetainsDisconnectFlushStrikes(t *testing.T) {
	r := New(testLogger())
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	dieAbruptlyWithFlush(t, r, "s1")
	assertIdentityQuarantine(t, r, "s1", true)

	// The zombie signature: same binary, churning reconnects. Nothing resets.
	bindVersionedSession(t, r, "s2", "0.9.0", false)
	assertIdentityQuarantine(t, r, "s2", true)
}

// A version bump removes ONLY the flush 502s: genuine 500 faults recorded on
// the old binary still satisfy every trip condition, so the quarantines stay.
func TestVersionChangedReconnect_KeepsGenuineFaults(t *testing.T) {
	r := New(testLogger())
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	for i := 0; i < 2; i++ {
		r.RecordInferenceError("s1", "m", 500, "base")
	}
	for i := 0; i < 5; i++ {
		r.RecordProviderOutcome("s1", false, 500, "internal error")
	}
	for i := 0; i < 8; i++ {
		r.RecordProviderServeOutcome(versionResetStable, false, 500, "internal error")
	}
	assertIdentityQuarantine(t, r, "s1", true)
	dieAbruptlyWithFlush(t, r, "s1")

	bindVersionedSession(t, r, "s2", "0.9.1", false)
	assertIdentityQuarantine(t, r, "s2", true)
}

// The first version ever observed for an identity only records it: strikes
// accumulated before any version was known (coordinator restart, un-versioned
// legacy session) are not wiped by the first versioned reconnect.
func TestVersionReconnect_FirstObservationOnlyRecords(t *testing.T) {
	r := New(testLogger())
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
	p := r.Register("s0", nil, msg)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: versionResetSerial})
	dieAbruptlyWithFlush(t, r, "s0")
	assertIdentityQuarantine(t, r, "s0", true)

	bindVersionedSession(t, r, "s1", "0.9.5", false)
	assertIdentityQuarantine(t, r, "s1", true)
}

// A graceful (peer-close) flush never strikes in the first place, so nothing
// is left to reset: the reconnect on any version finds a clean identity.
func TestGracefulDisconnect_NoStrikesToReset(t *testing.T) {
	r := New(testLogger())
	p := bindVersionedSession(t, r, "s1", "0.9.0", true)
	for i := 0; i < 3; i++ {
		p.AddPending(&PendingRequest{
			RequestID: fmt.Sprintf("s1-req-%d", i),
			Model:     "m",
			ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
		})
	}
	r.DisconnectWithReason("s1", DisconnectReasonPeerClose)
	// The api layer's noteInferenceError gates on the provider_restart reason
	// before any Record* call, so the registry sees no strikes at all.
	assertIdentityQuarantine(t, r, "s1", false)
	bindVersionedSession(t, r, "s2", "0.9.0", false)
	assertIdentityQuarantine(t, r, "s2", false)
}

// RegisterMessage.Version is provider-asserted, so the reset is rate-limited
// per identity: a second version change inside identityVersionResetMinInterval
// retains the strikes (a modified binary alternating two version strings
// cannot launder every reconnect), and the reset is available again once the
// interval has elapsed (a genuine later rollout).
func TestVersionChangedReconnect_ResetIsRateLimitedPerIdentity(t *testing.T) {
	r := New(testLogger())
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	dieAbruptlyWithFlush(t, r, "s1")
	assertIdentityQuarantine(t, r, "s1", true)

	// First version change: reset consumed.
	bindVersionedSession(t, r, "s2", "0.9.1", false)
	assertIdentityQuarantine(t, r, "s2", false)
	dieAbruptlyWithFlush(t, r, "s2")
	assertIdentityQuarantine(t, r, "s2", true)

	// Second change inside the interval: strikes retained.
	bindVersionedSession(t, r, "s3", "0.9.2", false)
	assertIdentityQuarantine(t, r, "s3", true)

	// Once the interval has elapsed the reset is available again.
	withGateForKey(r, versionResetStable, func(g *gateState) { g.versionResetAt = time.Now().Add(-identityVersionResetMinInterval - time.Second) })
	bindVersionedSession(t, r, "s4", "0.9.3", false)
	assertIdentityQuarantine(t, r, "s4", false)
}

// TestInferenceFlushStrikes_BoundedForSameVersionIdentity: an identity that
// churns on the SAME binary version never triggers the version reset, so its
// disconnect-flush tags were append-only — the main strikes slid out of the
// breaker window and a success deleted them, but every flushed request kept a
// time.Time under the identity forever. Seed 10,000 flushed requests spread
// over hours (each also in the main strike list, exactly as RecordInferenceError
// writes them), record one more flush, and the tag slice must be bounded by
// the breaker window and remain a subset of the strikes; a success clears it.
func TestInferenceFlushStrikes_BoundedForSameVersionIdentity(t *testing.T) {
	r := New(testLogger())
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	key := modelShapeKey{Model: "m", Shape: "base"}
	g := r.gateForSession("s1").g

	const flushed = 10_000
	now := time.Now()
	seed := make([]time.Time, 0, flushed)
	for i := 0; i < flushed; i++ {
		// One flush every 2 s, the newest 2 s ago: ~30 fall inside the 60 s
		// breaker window, the rest are hours old.
		seed = append(seed, now.Add(-time.Duration(flushed-i)*2*time.Second))
	}
	g.mu.Lock()
	g.inferenceErrorStrikes[key] = append([]time.Time(nil), seed...)
	if g.inferenceErrorFlushStrikes == nil {
		g.inferenceErrorFlushStrikes = make(map[modelShapeKey][]time.Time)
	}
	g.inferenceErrorFlushStrikes[key] = append([]time.Time(nil), seed...)
	g.publishLocked()
	g.mu.Unlock()

	r.RecordInferenceError("s1", "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)

	g.mu.Lock()
	strikes := append([]time.Time(nil), g.inferenceErrorStrikes[key]...)
	flush := append([]time.Time(nil), g.inferenceErrorFlushStrikes[key]...)
	g.publishLocked()
	g.mu.Unlock()
	if len(strikes) == 0 {
		t.Fatal("main strike list is empty after a recorded flush")
	}
	// The bound is the breaker window: everything older than 60 s is gone.
	// 30 seeded entries at most survive (2 s spacing) plus the strike just
	// recorded; allow the wall clock a little drift.
	if len(flush) > int(inferenceErrorWindow/(2*time.Second))+2 {
		t.Fatalf("flush tags = %d after %d historical flushes, want the slice bounded by the %s window", len(flush), flushed, inferenceErrorWindow)
	}
	if len(flush) > len(strikes) {
		t.Fatalf("flush tags (%d) outnumber live strikes (%d)", len(flush), len(strikes))
	}
	for _, ts := range flush {
		if !containsTimestamp(strikes, ts) {
			t.Fatalf("flush tag %v marks a strike that is no longer in the window", ts)
		}
		if now.Sub(ts) >= inferenceErrorWindow+time.Second {
			t.Fatalf("flush tag %v is older than the breaker window", ts)
		}
	}
	if !containsTimestamp(flush, strikes[len(strikes)-1]) {
		t.Fatal("the flush just recorded is not tagged")
	}

	// A served request clears the shape's history — tags included.
	r.RecordInferenceSuccess("s1", "m", "base")
	g.mu.Lock()
	_, strikesLeft := g.inferenceErrorStrikes[key]
	_, flushLeft := g.inferenceErrorFlushStrikes[key]
	g.publishLocked()
	g.mu.Unlock()
	if strikesLeft || flushLeft {
		t.Fatalf("after success: strikes present=%v flush tags present=%v, want both cleared", strikesLeft, flushLeft)
	}
}

// TestInferenceFlushStrikes_NonFlushStrikePrunesTags: the tags slide out of
// the window on EVERY counted strike, not only on a 502, so they can never
// reference a strike the main list has already dropped.
func TestInferenceFlushStrikes_NonFlushStrikePrunesTags(t *testing.T) {
	r := New(testLogger())
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	key := modelShapeKey{Model: "m", Shape: "base"}
	g := r.gateForSession("s1").g

	stale := time.Now().Add(-2 * inferenceErrorWindow)
	g.mu.Lock()
	g.inferenceErrorStrikes[key] = []time.Time{stale}
	g.inferenceErrorFlushStrikes = map[modelShapeKey][]time.Time{key: {stale}}
	g.publishLocked()
	g.mu.Unlock()

	r.RecordInferenceError("s1", "m", 500, "base")

	g.mu.Lock()
	flush, present := g.inferenceErrorFlushStrikes[key]
	g.publishLocked()
	g.mu.Unlock()
	if present {
		t.Fatalf("stale flush tag survived a non-flush strike: %v", flush)
	}
}

// dieAbruptlyWithFlushKeyed is dieAbruptlyWithFlush for a session bound to an
// arbitrary stable identity (the serial fixture above is hardcoded).
func dieAbruptlyWithFlushKeyed(t *testing.T, r *Registry, id, stable string) {
	t.Helper()
	p := r.GetProvider(id)
	if p == nil {
		t.Fatalf("provider %s not registered", id)
	}
	for i := 0; i < 3; i++ {
		p.AddPending(&PendingRequest{
			RequestID: fmt.Sprintf("%s-req-%d", id, i),
			Model:     "m",
			ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
		})
	}
	r.DisconnectWithReason(id, DisconnectReasonReadError)
	if sid := r.GetProviderStableIdentity(id); sid != stable {
		t.Fatalf("stable identity after disconnect = %q, want %q", sid, stable)
	}
	for i := 0; i < 2; i++ {
		r.RecordInferenceError(id, "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)
	}
	for i := 0; i < 5; i++ {
		r.RecordProviderOutcome(id, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
	for i := 0; i < 8; i++ {
		r.RecordProviderServeOutcome(stable, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
}

func assertIdentityQuarantineKeyed(t *testing.T, r *Registry, queryID, stable string, want bool) {
	t.Helper()
	if got := r.InferenceErrorCooldownActive(queryID, "m", "base"); got != want {
		t.Errorf("InferenceErrorCooldownActive(%s) = %v, want %v", queryID, got, want)
	}
	if got := r.ProviderBreakerOpen(queryID); got != want {
		t.Errorf("ProviderBreakerOpen(%s) = %v, want %v", queryID, got, want)
	}
	if got := r.HealthEjectionOpen(stable); got != want {
		t.Errorf("HealthEjectionOpen(%s) = %v, want %v", stable, got, want)
	}
}

// TestVersionResetThrottle_FollowsIdentityRebind: the per-identity reset
// timestamp must migrate with the identity on a sekey: → serial: rebind (MDA
// enrichment of a live session). Otherwise the serial identity starts with no
// throttle record and a second version change inside the 10-minute interval
// clears its flush strikes again — the laundering the interval exists to stop.
func TestVersionResetThrottle_FollowsIdentityRebind(t *testing.T) {
	r := New(testLogger())
	const pk, serial = "PK-REBIND", "SER-REBIND"
	const sekeyID, serialID = "sekey:" + pk, "serial:" + serial
	register := func(id string) *Provider {
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
		return r.Register(id, nil, msg)
	}
	attestSEKey := func(p *Provider) {
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: pk})
	}

	// s1 on 0.9.0 binds the SE-key identity and dies abruptly with work in flight.
	s1 := register("s1")
	s1.SetVersion("0.9.0")
	attestSEKey(s1)
	dieAbruptlyWithFlushKeyed(t, r, "s1", sekeyID)
	assertIdentityQuarantineKeyed(t, r, "s1", sekeyID, true)

	// s2 on 0.9.1: the version change consumes the identity's one reset.
	s2 := register("s2")
	attestSEKey(s2)
	s2.SetVersion("0.9.1")
	assertIdentityQuarantineKeyed(t, r, "s2", sekeyID, false)
	dieAbruptlyWithFlushKeyed(t, r, "s2", sekeyID)
	assertIdentityQuarantineKeyed(t, r, "s2", sekeyID, true)

	// s3 binds the SE key, is enriched to the serial (rebind), and only then
	// reports a third version. The reset consumed under sekey: still throttles
	// the serial: identity.
	s3 := register("s3")
	attestSEKey(s3)
	s3.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: pk, SerialNumber: serial})
	if got := faultKeyOf(r, "s3"); got != serialID {
		t.Fatalf("enriched attestation must rebind to the serial key, got %q", got)
	}
	s3.SetVersion("0.9.2")
	assertIdentityQuarantineKeyed(t, r, "s3", serialID, true)

	orphan := rawGateForKey(r, sekeyID) != nil
	moved := false
	readGateForKey(r, serialID, func(g *gateState) { moved = g != nil && !g.versionResetAt.IsZero() })
	if orphan || !moved {
		t.Fatalf("reset timestamp after rebind: under old key=%v, under new key=%v; want moved", orphan, moved)
	}
}

// Both keys holding a reset timestamp merge to the LATER one, whichever side
// it is on, so a rebind can never shorten the interval.
func TestMigrateFaultState_ResetTimestampKeepsLater(t *testing.T) {
	older := time.Now().Add(-5 * time.Minute)
	newer := time.Now()
	for _, tc := range []struct {
		name     string
		src, dst time.Time
	}{
		{"newer source wins", newer, older},
		{"newer destination kept", older, newer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			withGateForKey(r, "old", func(g *gateState) { g.versionResetAt = tc.src })
			withGateForKey(r, "new", func(g *gateState) { g.versionResetAt = tc.dst })
			r.gatesMu.Lock()
			r.migrateGateLocked(&Provider{}, r.gates["old"], r.gates["new"], true)
			got := r.gates["new"].versionResetAt
			ok := !got.IsZero()
			_, orphan := r.gates["old"]
			r.gatesMu.Unlock()
			if !ok || !got.Equal(newer) {
				t.Fatalf("merged reset timestamp = %v (present=%v), want %v", got, ok, newer)
			}
			if orphan {
				t.Fatal("reset timestamp orphaned under the old key")
			}
		})
	}
}

// dropAbruptlyUnrecorded parks a request on the session and drops it without a
// close frame, leaving the flush 502 in the consumer's ErrorCh UNRECORDED —
// the state registration's duplicate-serial eviction leaves the old session
// in while it goes on to store the new version.
func dropAbruptlyUnrecorded(t *testing.T, r *Registry, id string) {
	t.Helper()
	p := r.GetProvider(id)
	if p == nil {
		t.Fatalf("provider %s not registered", id)
	}
	p.AddPending(&PendingRequest{
		RequestID: id + "-req",
		Model:     "m",
		ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
	})
	r.DisconnectWithReason(id, DisconnectReasonReadError)
}

// The predicate behind the api-side discard of late flush strikes: a 502 from
// a session dropped at or before its identity's last version-changed reset is
// superseded; a live session, a non-flush status, an identity that never
// reset, and a session dropped after the reset (including under a THROTTLED
// version change, which stamps no new reset) are not.
func TestSupersededDisconnectFlush_DatesTheDropAgainstTheReset(t *testing.T) {
	r := New(testLogger())
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	dropAbruptlyUnrecorded(t, r, "s1")
	if r.IsSupersededDisconnectFlush("s1", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("no reset has run: the flush strike must record")
	}

	// Registration order: the eviction above already happened when SetVersion
	// runs the reset against empty windows.
	bindVersionedSession(t, r, "s2", "0.9.1", false)
	if !r.IsSupersededDisconnectFlush("s1", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("s1 was dropped before the version reset: its flush strike is superseded")
	}
	if r.IsSupersededDisconnectFlush("s1", 500) {
		t.Fatal("only the disconnect-flush status is superseded, never a genuine fault")
	}
	if r.IsSupersededDisconnectFlush("s2", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("a live session is never superseded")
	}
	if r.IsSupersededDisconnectFlush("nobody", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("an unknown session is never superseded")
	}

	// The new binary dies too, and a THIRD version arrives inside the reset
	// interval: throttled, so no new reset is stamped and s2's flush strikes
	// (dropped after the only reset) must still land.
	dropAbruptlyUnrecorded(t, r, "s2")
	bindVersionedSession(t, r, "s3", "0.9.2", false)
	if r.IsSupersededDisconnectFlush("s2", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("s2 was dropped after the last reset (the next one was throttled): its flush strike must record")
	}
	if !r.IsSupersededDisconnectFlush("s1", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("s1's verdict does not change with later sessions")
	}
}

// No stable identity at disconnect → the registry never dated the drop and
// the strike keys by the session id anyway: not superseded.
func TestSupersededDisconnectFlush_UnattestedSessionIsNotDated(t *testing.T) {
	r := New(testLogger())
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
	p := r.Register("anon", nil, msg)
	p.SetVersion("0.9.0")
	dropAbruptlyUnrecorded(t, r, "anon")
	if r.IsSupersededDisconnectFlush("anon", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("a session without a stable identity is never superseded")
	}
}

// A reset can occur after the API precheck or between any pair of tracker
// writes. Every write retains the session id and checks inside its mutation
// lock; earlier writes are removed by the reset and later ones are discarded.
func TestVersionResetInterleavedWithTrackerWrites(t *testing.T) {
	for split := 0; split <= 3; split++ {
		t.Run(fmt.Sprintf("reset_after_%d_trackers", split), func(t *testing.T) {
			r := New(testLogger())
			bindVersionedSession(t, r, "old", "0.9.0", true)
			dropAbruptlyUnrecorded(t, r, "old")
			if r.IsSupersededDisconnectFlush("old", 502, protocol.CoordinatorCauseProviderDisconnected) {
				t.Fatal("API precheck before the reset must allow the old flush")
			}
			writes := []func(){
				func() { r.RecordInferenceError("old", "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected) },
				func() {
					r.RecordProviderOutcome("old", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
				},
				func() {
					r.RecordProviderSessionServeOutcome("old", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
				},
			}
			for _, write := range writes[:split] {
				for range 8 {
					write()
				}
			}
			bindVersionedSession(t, r, "new", "0.9.1", false)
			for _, write := range writes[split:] {
				for range 8 {
					write()
				}
			}
			assertIdentityQuarantine(t, r, "new", false)
		})
	}
}

// A disconnect cache must follow an identity enrichment just like the fault
// windows and reset timestamp. Otherwise a late old-session flush recreates
// the emptied sekey history and a later same-version reconnect merges those
// superseded faults back into the serial identity.
func TestVersionResetSurvivesDisconnectedIdentityEnrichment(t *testing.T) {
	r := New(testLogger())
	const publicKey = "version-reset-shared-se-key"
	bindKey := func(id, version string) *Provider {
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
		p := r.Register(id, nil, msg)
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: publicKey})
		p.SetVersion(version)
		return p
	}
	enrich := func(p *Provider) {
		p.SetAttestationResult(&attestation.VerificationResult{
			Valid: true, PublicKey: publicKey, SerialNumber: versionResetSerial,
		})
	}
	bindKey("old-key-session", "0.9.0")
	dropAbruptlyUnrecorded(t, r, "old-key-session")
	current := bindKey("current-key-session", "0.9.1")
	enrich(current)
	for range 8 {
		r.RecordInferenceError("old-key-session", "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)
		r.RecordProviderOutcome("old-key-session", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
		r.RecordProviderSessionServeOutcome("old-key-session", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
	// Reconnecting through the weaker identity must not resurrect the old
	// binary's flushes when the same serial is attested again.
	next := bindKey("next-key-session", "0.9.1")
	enrich(next)
	assertIdentityQuarantine(t, r, next.ID, false)
	if got := r.GetProviderStableIdentity("old-key-session"); got != versionResetStable {
		t.Fatalf("disconnected identity = %q, want enriched %q", got, versionResetStable)
	}
}
