package registry_test

import (
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestVersionChangedReconnect_ClearsDisconnectFlushStrikes(t *testing.T) {
	for _, versionFirst := range []bool{true, false} {
		name := "registration order (bind then SetVersion)"
		if versionFirst {
			name = "re-attestation order (SetVersion then bind)"
		}
		t.Run(name, func(t *testing.T) {
			r := production.New(testLogger())
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
	r := production.New(testLogger())
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
	r := production.New(testLogger())
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
	r := production.New(testLogger())
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
	r := production.New(testLogger())
	p := bindVersionedSession(t, r, "s1", "0.9.0", true)
	for i := 0; i < 3; i++ {
		p.AddPending(&production.PendingRequest{
			RequestID: fmt.Sprintf("s1-req-%d", i),
			Model:     "m",
			ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
		})
	}
	r.DisconnectWithReason("s1", production.DisconnectReasonPeerClose)
	// The api layer's noteInferenceError gates on the provider_restart reason
	// before any Record* call, so the registry sees no strikes at all.
	assertIdentityQuarantine(t, r, "s1", false)
	bindVersionedSession(t, r, "s2", "0.9.0", false)
	assertIdentityQuarantine(t, r, "s2", false)
}

// dropAbruptlyUnrecorded parks a request on the session and drops it without a
// close frame, leaving the flush 502 in the consumer's ErrorCh UNRECORDED —
// the state registration's duplicate-serial eviction leaves the old session
// in while it goes on to store the new version.
func dropAbruptlyUnrecorded(t *testing.T, r *production.Registry, id string) {
	t.Helper()
	p := r.GetProvider(id)
	if p == nil {
		t.Fatalf("provider %s not registered", id)
	}
	p.AddPending(&production.PendingRequest{
		RequestID: id + "-req",
		Model:     "m",
		ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
	})
	r.DisconnectWithReason(id, production.DisconnectReasonReadError)
}

// The predicate behind the api-side discard of late flush strikes: a 502 from
// a session dropped at or before its identity's last version-changed reset is
// superseded; a live session, a non-flush status, an identity that never
// reset, and a session dropped after the reset (including under a THROTTLED
// version change, which stamps no new reset) are not.
func TestSupersededDisconnectFlush_DatesTheDropAgainstTheReset(t *testing.T) {
	r := production.New(testLogger())
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
	r := production.New(testLogger())
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
			r := production.New(testLogger())
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
	r := production.New(testLogger())
	const publicKey = "version-reset-shared-se-key"
	bindKey := func(id, version string) *production.Provider {
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
		p := r.Register(id, nil, msg)
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: publicKey})
		p.SetVersion(version)
		return p
	}
	enrich := func(p *production.Provider) {
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

// The reset throttle must migrate from an SE-key identity to the serial identity.
func TestVersionResetThrottle_FollowsIdentityRebind(t *testing.T) {
	now := time.Now()
	r, gates, clock := newVersionGateRegistry(now)
	const pk, serial = "PK-REBIND", "SER-REBIND"
	const sekeyID, serialID = "sekey:" + pk, "serial:" + serial
	register := func(id string) *production.Provider {
		msg := testRegisterMessage()
		msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
		return r.Register(id, nil, msg)
	}
	attestSEKey := func(p *production.Provider) {
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: pk})
	}

	s1 := register("s1")
	s1.SetVersion("0.9.0")
	attestSEKey(s1)
	dieAbruptlyWithFlushKeyed(t, r, "s1", sekeyID)
	assertIdentityQuarantineKeyed(t, r, "s1", sekeyID, true)

	s2 := register("s2")
	attestSEKey(s2)
	s2.SetVersion("0.9.1")
	assertIdentityQuarantineKeyed(t, r, "s2", sekeyID, false)
	clock.set(now.Add(time.Nanosecond))
	dieAbruptlyWithFlushKeyed(t, r, "s2", sekeyID)
	assertIdentityQuarantineKeyed(t, r, "s2", sekeyID, true)

	s3 := register("s3")
	attestSEKey(s3)
	s3.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: pk, SerialNumber: serial})
	if got := r.GetProviderStableIdentity("s3"); got != serialID {
		t.Fatalf("enriched attestation must rebind to the serial key, got %q", got)
	}
	s3.SetVersion("0.9.2")
	assertIdentityQuarantineKeyed(t, r, "s3", serialID, true)

	orphan := gates.ViewIdentity(sekeyID).Present()
	// An old flush stays superseded only if the reset fence moved to serialID.
	moved := r.IsSupersededDisconnectFlush("s1", 502, protocol.CoordinatorCauseProviderDisconnected)
	if orphan || !moved {
		t.Fatalf("reset timestamp after rebind: under old key=%v, under new key=%v; want moved", orphan, moved)
	}
}

// Both keys holding a reset timestamp merge to the later one, whichever side
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
			_, gates, clock := newVersionGateRegistry(tc.src)
			reset := func(key string, at time.Time) *identitygate.Session {
				clock.set(at)
				session := gates.Attach(key + "-session")
				gates.Bind(session, key, "0.9.0")
				gates.ObserveVersion(session, "0.9.1")
				return session
			}
			source := reset("old", tc.src)
			reset("new", tc.dst)
			// Two real disconnects bracket the expected fence to one nanosecond.
			// Their unchanged versions leave the existing reset history intact.
			for _, witness := range []struct {
				id string
				at time.Time
			}{
				{"at-cutoff", newer},
				{"after-cutoff", newer.Add(time.Nanosecond)},
			} {
				clock.set(witness.at)
				session := gates.Attach(witness.id)
				gates.Bind(session, "new", "0.9.1")
				gates.Detach(session, "new")
			}
			gates.Bind(source, "new", "0.9.1")
			at := gates.IsSupersededDisconnectFlush("at-cutoff", 502, protocol.CoordinatorCauseProviderDisconnected)
			after := gates.IsSupersededDisconnectFlush("after-cutoff", 502, protocol.CoordinatorCauseProviderDisconnected)
			got := fmt.Sprintf("superseded at cutoff=%v, after cutoff=%v", at, after)
			ok := at && !after
			orphan := gates.ViewIdentity("old").Present()
			if !ok {
				t.Fatalf("merged reset timestamp = %v (present=%v), want %v", got, at, newer)
			}
			if orphan {
				t.Fatal("reset timestamp orphaned under the old key")
			}
		})
	}
}

// Repeated version changes cannot launder disconnect faults during the reset
// interval. A later rollout can reset again once that real interval elapses.
func TestVersionChangedReconnect_ResetIsRateLimitedPerIdentity(t *testing.T) {
	now := time.Now()
	r, _, clock := newVersionGateRegistry(now)
	bindVersionedSession(t, r, "s1", "0.9.0", true)
	dieAbruptlyWithFlush(t, r, "s1")
	assertIdentityQuarantine(t, r, "s1", true)

	bindVersionedSession(t, r, "s2", "0.9.1", false)
	assertIdentityQuarantine(t, r, "s2", false)
	clock.set(now.Add(time.Nanosecond))
	dieAbruptlyWithFlush(t, r, "s2")
	assertIdentityQuarantine(t, r, "s2", true)

	bindVersionedSession(t, r, "s3", "0.9.2", false)
	assertIdentityQuarantine(t, r, "s3", true)

	clock.set(now.Add(10*time.Minute + time.Second))
	// Refresh real fault evidence after advancing time so an expired cooldown
	// cannot make the final clearing assertion pass without an actual reset.
	dieAbruptlyWithFlush(t, r, "s3")
	assertIdentityQuarantine(t, r, "s3", true)
	if r.IsSupersededDisconnectFlush("s3", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("a later disconnect was superseded before the next version reset")
	}
	bindVersionedSession(t, r, "s4", "0.9.3", false)
	assertIdentityQuarantine(t, r, "s4", false)
	if !r.IsSupersededDisconnectFlush("s3", 502, protocol.CoordinatorCauseProviderDisconnected) {
		t.Fatal("elapsed reset interval did not permit a new disconnect fence")
	}
}

// Same-version churn never invokes reset cleanup. Every inference failure must
// bound its provenance tags together with its main strike history.
func TestInferenceFlushStrikes_BoundedForSameVersionIdentity(t *testing.T) {
	var history identitygate.InferenceHistory
	const flushed = 10_000
	now := time.Now()
	seed := make([]time.Time, 0, flushed)
	for i := 0; i < flushed; i++ {
		// One flush every 2 s, newest 2 s ago; most are hours old.
		seed = append(seed, now.Add(-time.Duration(flushed-i)*2*time.Second))
	}
	// Real identity-history merging retains unpruned, chronological evidence.
	// Single-event histories assemble the original 10,000-entry precondition
	// without running the write-time pruning policy on the aggregate yet.
	for _, at := range seed {
		var event identitygate.InferenceHistory
		event.Record("m", "base", at, true)
		history.Merge(&event)
	}
	if strikes, flush := history.Chronological("m", "base"); len(strikes) != flushed || len(flush) != flushed {
		t.Fatalf("historical merge retained %d strikes and %d tags, want %d each", len(strikes), len(flush), flushed)
	}

	history.Record("m", "base", now, true)
	strikes, flush := history.Chronological("m", "base")
	if len(strikes) == 0 {
		t.Fatal("main strike list is empty after a recorded flush")
	}
	if len(flush) > int(inferenceErrorWindow/(2*time.Second))+2 {
		t.Fatalf("flush tags = %d after %d historical flushes, want the slice bounded by the %s window", len(flush), flushed, inferenceErrorWindow)
	}
	if len(flush) > len(strikes) {
		t.Fatalf("flush tags (%d) outnumber live strikes (%d)", len(flush), len(strikes))
	}
	for _, ts := range flush {
		if !slices.ContainsFunc(strikes, ts.Equal) {
			t.Fatalf("flush tag %v marks a strike that is no longer in the window", ts)
		}
		if now.Sub(ts) >= inferenceErrorWindow+time.Second {
			t.Fatalf("flush tag %v is older than the breaker window", ts)
		}
	}
	if !slices.ContainsFunc(flush, strikes[len(strikes)-1].Equal) {
		t.Fatal("the flush just recorded is not tagged")
	}

	history.Clear("m", "base")
	retained := history.Prune(now)
	strikesLeft, flushLeft := retained.StrikeBuckets != 0, retained.FlushBuckets != 0
	if strikesLeft || flushLeft {
		t.Fatalf("after success: strikes present=%v flush tags present=%v, want both cleared", strikesLeft, flushLeft)
	}
}

// Every counted failure prunes expired provenance, not only another flush.
func TestInferenceFlushStrikes_NonFlushStrikePrunesTags(t *testing.T) {
	var history identitygate.InferenceHistory
	now := time.Now()
	stale := now.Add(-2 * inferenceErrorWindow)
	history.Record("m", "base", stale, true)
	history.Record("m", "base", now, false)
	_, flush := history.Chronological("m", "base")
	present := history.Prune(now).FlushBuckets != 0
	if present {
		t.Fatalf("stale flush tag survived a non-flush strike: %v", flush)
	}
}
