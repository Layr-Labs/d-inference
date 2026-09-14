package trustreuse

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
	"time"
)

// TestTrustReuseContinuityFastSkip: a provider whose wall-clock window is
// STALE but whose coordinator-measured offline gap (45s) is within the
// reconnect allowance fast-skips with the distinct "continuity" decision and
// no live MDM round. Fails on the pre-continuity behavior (proof_expired).
func TestTrustReuseContinuityFastSkip(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	now := srv.cache.now()
	provedAt := now.Add(-20 * time.Minute) // far beyond the 5m window
	srv.cache.recordTrust(coveredReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA, provedAt, now.Add(-45*time.Second)))

	if result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashA,
	}); result.Decision != DecisionContinuity {
		t.Fatalf("decision = %q reason = %q, want %q",
			result.Decision, result.Reason, DecisionContinuity)
	}
	if !srv.TryReuse("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("stale window + 45s coordinator-measured gap must continuity fast-skip")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("trust = %q, want hardware via continuity", lvl)
	}
	// The grant re-anchors coverage at the grant instant (chain continues) but
	// NEVER advances the hardware-proof timestamp.
	srv.cache.mu.Lock()
	rec := srv.cache.records["se-pub-key-bytes"]
	srv.cache.mu.Unlock()
	if !rec.hardwareProofVerifiedAt.Equal(provedAt) {
		t.Fatalf("hardware proof advanced to %s by reuse; must stay %s",
			rec.hardwareProofVerifiedAt, provedAt)
	}
	if !rec.continuousCoverageUntil.Equal(now) {
		t.Fatalf("coverage = %s, want re-anchored at grant time %s",
			rec.continuousCoverageUntil, now)
	}
}

// TestTrustReuseContinuityRefusesLongGap: a 3-minute coordinator-measured gap
// exceeds the allowance (and could span a RecoveryOS round-trip), so the
// fast-skip declines and the provider falls back to full live verification.
func TestTrustReuseContinuityRefusesLongGap(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	now := srv.cache.now()
	srv.cache.recordTrust(coveredReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA,
		now.Add(-20*time.Minute), now.Add(-3*time.Minute)))

	if result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != ReasonProofExpired {
		t.Fatalf("decision = %q reason = %q, want expired rejection", result.Decision, result.Reason)
	}
	if srv.TryReuse("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("a 3m gap must refuse continuity and fall through to full live verification")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Fatalf("trust = %q after declined fast path, want self_signed", lvl)
	}
}

// TestTrustReuseContinuityChainedGaps: three consecutive 50s reconnect gaps
// each fast-skip — every continuity grant re-proves a normal-OS boot via the
// live SE challenge and re-anchors coverage, so chaining is intended. The
// hardware-proof timestamp never moves.
func TestTrustReuseContinuityChainedGaps(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	cur := srv.cache.now()
	srv.cache.now = func() time.Time { return cur }
	provedAt := cur.Add(-20 * time.Minute)
	srv.cache.recordTrust(coveredReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA, provedAt, cur))

	for i := range 3 {
		cur = cur.Add(50 * time.Second) // offline gap since the last coverage anchor
		if !srv.TryReuse("prov-fs", p, goodFastSkipResp(), true) {
			t.Fatalf("chained gap #%d (50s) must continuity fast-skip", i+1)
		}
		srv.cache.mu.Lock()
		rec := srv.cache.records["se-pub-key-bytes"]
		srv.cache.mu.Unlock()
		if !rec.continuousCoverageUntil.Equal(cur) {
			t.Fatalf("gap #%d: coverage = %s, want re-anchored at %s", i+1, rec.continuousCoverageUntil, cur)
		}
		if !rec.hardwareProofVerifiedAt.Equal(provedAt) {
			t.Fatalf("gap #%d: hardware proof advanced by reuse", i+1)
		}
	}
}

// TestTrustReuseContinuityCrashSlack: after a coordinator crash the watermark
// lags the true disconnect by up to one periodic pass (25s here). The measured
// gap therefore INCLUDES that slack: a reconnect is admitted only when
// slack + offline time fits the allowance, and refused beyond it (gap only
// ever over-estimated — fail-safe).
func TestTrustReuseContinuityCrashSlack(t *testing.T) {
	for _, tc := range []struct {
		name    string
		offline time.Duration
		want    bool
	}{
		{"slack_plus_60s_admits", 60 * time.Second, true},   // 25+60 = 85s <= 90s
		{"slack_plus_70s_refuses", 70 * time.Second, false}, // 25+70 = 95s > 90s
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, p, _ := trustReuseFastSkipProvider(t)
			disconnectAt := srv.cache.now()
			// Crash-style coverage: the last periodic write landed 25s before
			// the (unstamped) disconnect.
			srv.cache.recordTrust(coveredReuseRecord(
				"se-pub-key-bytes", "SERIAL-1", trHashA,
				disconnectAt.Add(-20*time.Minute), disconnectAt.Add(-25*time.Second)))
			reconnectAt := disconnectAt.Add(tc.offline)
			srv.cache.now = func() time.Time { return reconnectAt }

			got := srv.TryReuse("prov-fs", p, goodFastSkipResp(), true)
			if got != tc.want {
				t.Fatalf("fast-skip = %v, want %v (measured gap %s, allowance %s)",
					got, tc.want, tc.offline+25*time.Second, defaultTrustReuseReconnectGap)
			}
		})
	}
}

// TestTrustReuseContinuityNeverForHardUntrusted: a durable tombstone wins over
// any coverage watermark — a hard-untrusted identity never continuity-skips.
func TestTrustReuseContinuityNeverForHardUntrusted(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	now := srv.cache.now()
	srv.cache.recordTrust(coveredReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA,
		now.Add(-20*time.Minute), now.Add(-10*time.Second)))
	srv.cache.invalidateReuse("se-pub-key-bytes", "evt-hard-untrust")

	if result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != ReasonRevoked {
		t.Fatalf("decision = %q reason = %q, want revoked rejection", result.Decision, result.Reason)
	}
	if srv.TryReuse("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("a tombstoned identity must never continuity fast-skip")
	}
}

// TestTrustReuseContinuityNeverForBadPosture: recorded-posture-good stays a
// mandatory gate — current coverage cannot admit a record whose last full
// verification saw bad posture.
func TestTrustReuseContinuityNeverForBadPosture(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	now := srv.cache.now()
	rec := coveredReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA,
		now.Add(-20*time.Minute), now.Add(-10*time.Second))
	rec.SecureBootFull = false
	srv.cache.recordTrust(rec)

	if result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != ReasonRecordedPostureBad {
		t.Fatalf("decision = %q reason = %q, want recorded_posture_bad", result.Decision, result.Reason)
	}
	if srv.TryReuse("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("bad recorded posture must never continuity fast-skip")
	}
}

// TestTrustReuseContinuityNeverForUnapprovedTransition: the approved-release
// gate stays mandatory — continuity admits staleness, never a binary change
// without a server-derived approved transition fact.
func TestTrustReuseContinuityNeverForUnapprovedTransition(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	now := srv.cache.now()
	srv.cache.recordTrust(coveredReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA,
		now.Add(-20*time.Minute), now.Add(-10*time.Second)))

	resp := goodFastSkipResp()
	resp.BinaryHash = trHashB // changed binary, no approved fact
	if result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashB,
	}); result.Decision != "" || result.Reason != ReasonTransitionUnapproved {
		t.Fatalf("decision = %q reason = %q, want transition_unapproved", result.Decision, result.Reason)
	}
	if srv.TryReuse("prov-fs", p, resp, true) {
		t.Fatal("an unapproved release transition must never continuity fast-skip")
	}
}

// TestTrustReuseStaleWindowWithoutCoverageNeverFastSkips pins premise (a)'s
// tightened bound in isolation: a 6-minute-old record with NO coverage
// watermark never fast-skips. Under the previous 10-minute default this
// granted — the test fails on the old behavior.
func TestTrustReuseStaleWindowWithoutCoverageNeverFastSkips(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	now := srv.cache.now()
	srv.cache.recordTrust(hardwareReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA, now.Add(-6*time.Minute)))

	if result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != ReasonProofExpired {
		t.Fatalf("decision = %q reason = %q, want expired (5m window, no coverage)", result.Decision, result.Reason)
	}
	if srv.TryReuse("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("a 6m-old record without coverage must not fast-skip under the 5m window")
	}
}

// TestTrustCoverageSweepAndDisconnectStamp exercises the coverage machinery
// end-to-end against the durable store: the batched periodic sweep advances
// the watermark only for connections still observed live and hardware-trusted,
// coverage stops (without a write) on trust loss, and the disconnect sweep
// stamps the EXACT disconnect instant.
func TestTrustCoverageSweepAndDisconnectStamp(t *testing.T) {
	srv, st := trustReuseServer(t)
	t.Cleanup(srv.Close)
	cur := time.Unix(1_700_000_000, 0)
	srv.cache.now = func() time.Time { return cur }
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("seed: %v", err)
	}

	p := newTrustReuseProvider(t, srv, "prov-cov", "se-cov", "SER-COV")
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()
	rec := hardwareReuseRecord("se-cov", "SER-COV", trHashA, cur)
	if _, err := st.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	srv.cache.recordTrust(rec)
	srv.MarkCoverage("se-cov", "prov-cov")

	// Batched periodic pass advances the durable watermark to now.
	cur = cur.Add(30 * time.Second)
	if n := srv.sweepTrustCoverage(); n != 1 {
		t.Fatalf("sweep advanced %d identities, want 1", n)
	}
	rows, _ := st.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].ContinuousCoverageUntil == nil ||
		!rows[0].ContinuousCoverageUntil.Equal(cur) {
		t.Fatalf("durable coverage = %+v, want watermark %s", rows, cur)
	}

	// Trust loss ends coverage WITHOUT a write: the sweep drops the entry and
	// the watermark stays where it was (never advances while unproven).
	watermark := cur
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.Mu().Unlock()
	cur = cur.Add(30 * time.Second)
	if n := srv.sweepTrustCoverage(); n != 0 {
		t.Fatalf("sweep advanced %d identities after trust loss, want 0", n)
	}
	rows, _ = st.ListProviderTrustReuse(context.Background())
	if !rows[0].ContinuousCoverageUntil.Equal(watermark) {
		t.Fatalf("coverage advanced to %s while unproven, must stay %s",
			rows[0].ContinuousCoverageUntil, watermark)
	}

	// Re-trust + re-mark, then a disconnect stamps the exact instant even
	// though the provider socket (status) is already down.
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Status = registry.StatusOffline
	p.Mu().Unlock()
	srv.MarkCoverage("se-cov", "prov-cov")
	cur = cur.Add(17 * time.Second)
	srv.StopProviderCoverage("prov-cov")
	rows, _ = st.ListProviderTrustReuse(context.Background())
	if !rows[0].ContinuousCoverageUntil.Equal(cur) {
		t.Fatalf("disconnect stamp = %s, want exact disconnect time %s",
			rows[0].ContinuousCoverageUntil, cur)
	}
	// The entry is gone: a later sweep writes nothing.
	cur = cur.Add(30 * time.Second)
	if n := srv.sweepTrustCoverage(); n != 0 {
		t.Fatalf("sweep advanced %d identities after disconnect, want 0", n)
	}
}
