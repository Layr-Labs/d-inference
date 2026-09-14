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
	r := newClockedFaultRegistry(t)
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
	advanceFaultFixtureTime(r, identityVersionResetMinInterval+time.Second)
	// Keep fresh quarantine at the advanced clock: ordinary cooldown expiry
	// must not make the final reset assertion pass without a version reset.
	for range healthEjectionConsecTrip {
		r.RecordInferenceError("s3", "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)
		r.RecordProviderOutcome("s3", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
		r.RecordProviderSessionServeOutcome("s3", false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
	assertIdentityQuarantine(t, r, "s3", true)
	bindVersionedSession(t, r, "s4", "0.9.3", false)
	assertIdentityQuarantine(t, r, "s4", false)
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
	moved := !r.faults.StatusForKey(serialID, "", "").VersionResetAt.IsZero()
	if orphan || !moved {
		t.Fatalf("reset timestamp after rebind: under old key=%v, under new key=%v; want moved", orphan, moved)
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
