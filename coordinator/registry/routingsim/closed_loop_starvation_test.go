package routingsim

import (
	"fmt"
	"testing"
	"testing/synctest"
	"time"
)

// explorationPolicyBound is the longest time an idle, loaded provider may go
// without usable evidence before routing must let it compete for work again.
// The value mirrors firstContentEvidenceExplorationAfter from #1254 (5
// minutes). This package tests the public registry API and cannot read that
// unexported constant, so a change to it must be copied here. It is a policy
// number, not a measured optimum, and the maintainers own it.
const explorationPolicyBound = 5 * time.Minute

// noStarvationBound adds the time for one request to the policy bound. A
// provider that is admitted at the bound competes with idle peers, and one
// request time covers that competition.
//
// This bound asserts a proposed policy, not the behavior of #1243 or #1254.
// #1254 admits a provider to the pool at the bound but does not promise that
// it is selected. #1243 keeps an old decode rate for 30 minutes on purpose.
// The proposed policy goes beyond both: an explored provider is costed at the
// fleet median for prefill and decode from the bound, and it is selected
// within the bound plus one request. The maintainers own this policy.
const noStarvationBound = explorationPolicyBound + loopRequestServiceTime

// loopDuration is the length of every arrival stream.
const loopDuration = 2 * time.Hour

// loopControlBusiestSharePct is a loose upper limit on the share of requests
// that the busiest provider takes in the healthy control fleet. A fair share
// in that fleet is 100/22, about 4.5 percent.
const loopControlBusiestSharePct = 10.0

// slowTargetStreamStart is when demand arrives in scenario (a). It is longer
// than the two-minute evidence window after the target's last measurement.
const slowTargetStreamStart = 3 * time.Minute

var loopPaths = []measurementPath{legacyTelemetryPath, explicitMeasurementPath}

// loopPeers returns n established providers. With loopRequestsInFlight peers,
// exactly one peer is idle, with current evidence, at each arrival.
func loopPeers(n int) []loopProviderSpec {
	peers := make([]loopProviderSpec, n)
	for i := range peers {
		peers[i] = loopProviderSpec{id: fmt.Sprintf("peer-%02d", i), established: true}
	}
	return peers
}

func runLoopScenario(t *testing.T, sc loopScenario) loopResult {
	t.Helper()
	var res loopResult
	synctest.Test(t, func(t *testing.T) {
		res = runClosedLoop(t, sc)
	})
	t.Logf("\n%s", res)
	return res
}

// assertNoStarvation checks that every provider was selected within
// noStarvationBound of becoming idle while requests arrived.
func assertNoStarvation(t *testing.T, res loopResult) {
	t.Helper()
	for _, p := range res.Providers {
		if p.MaxIdleWait > noStarvationBound {
			t.Errorf("seed %d: %s waited %s idle and loaded while requests arrived; bound is %s (selections=%d)",
				res.Seed, p.ID, p.MaxIdleWait, noStarvationBound, p.Selections)
		}
	}
	if res.Unserved != 0 {
		t.Errorf("seed %d: %d arrivals found no provider", res.Seed, res.Unserved)
	}
}

// TestClosedLoopSlowLastMeasurement is scenario (a) of #1238: the target's
// last measurement before it became idle was slow. The target measured that
// rate three minutes before demand arrives, so its evidence is already older
// than the two-minute evidence window. The peers served until just before
// demand arrives, so their evidence is current. The target's real rates equal
// the peers' rates, so one request would correct its measurement. The issue
// rate is the observed decode rate of 16.2 tok/s. The far-below decode rate is
// slow enough that one decode step moves the target's expected first content
// outside the 100 ms selection band. The slow-prefill variant applies the same
// question to the prefill measurement, which also has no age limit in
// resolvePrefillTPS.
func TestClosedLoopSlowLastMeasurement(t *testing.T) {
	for _, variant := range []struct {
		name            string
		decode, prefill float64
	}{
		{name: "issue_rate", decode: 16.2},
		{name: "far_below_median", decode: 5.0},
		{name: "slow_prefill", prefill: 400},
	} {
		for _, path := range loopPaths {
			t.Run(variant.name+"/"+string(path), func(t *testing.T) {
				target := loopProviderSpec{id: "target", established: true,
					lastDecodeTPS: variant.decode, lastPrefillTPS: variant.prefill}
				peers := loopPeers(loopRequestsInFlight)
				for i := range peers {
					peers[i].joinAt = slowTargetStreamStart - 5*time.Second
				}
				res := runLoopScenario(t, loopScenario{
					name:        "slow_last_measurement_" + variant.name,
					seed:        1238,
					path:        path,
					providers:   append(peers, target),
					streamStart: slowTargetStreamStart,
					duration:    loopDuration,
				})
				assertNoStarvation(t, res)
			})
		}
	}
}

// TestClosedLoopFreshProvider is scenario (b): a provider connects with no
// measurement while busy peers have current evidence.
func TestClosedLoopFreshProvider(t *testing.T) {
	for _, path := range loopPaths {
		t.Run(string(path), func(t *testing.T) {
			target := loopProviderSpec{id: "target", joinAt: 10 * time.Minute}
			res := runLoopScenario(t, loopScenario{
				name:        "fresh_provider",
				seed:        688,
				path:        path,
				providers:   append(loopPeers(loopRequestsInFlight), target),
				streamStart: 5 * time.Second,
				duration:    loopDuration,
			})
			assertNoStarvation(t, res)
			if p, ok := res.provider("target"); ok && p.FirstPick >= 0 {
				t.Logf("target first selected %s after the stream started, costed at %.1f tok/s", p.FirstPick, p.FirstPickTPS)
			}
		})
	}
}

// TestClosedLoopIdleBeyondEvidenceWindow is scenario (c): demand pauses for
// three minutes, longer than the two-minute evidence window, so every
// provider's evidence becomes stale. When demand returns, the providers that
// serve first get current evidence again. The fleet has one more provider
// than the stream keeps busy, so at least one provider remains idle.
func TestClosedLoopIdleBeyondEvidenceWindow(t *testing.T) {
	for _, path := range loopPaths {
		t.Run(string(path), func(t *testing.T) {
			res := runLoopScenario(t, loopScenario{
				name:        "idle_beyond_evidence_window",
				seed:        1254,
				path:        path,
				providers:   loopPeers(loopRequestsInFlight + 1),
				streamStart: 5 * time.Second,
				duration:    loopDuration,
				pauses:      []loopPause{{from: 20 * time.Minute, to: 23 * time.Minute}},
			})
			assertNoStarvation(t, res)
		})
	}
}

// TestClosedLoopHomogeneousControl is scenario (d): a healthy homogeneous
// fleet with two idle providers at each arrival. No provider may starve, and
// no provider may take much more than its share.
func TestClosedLoopHomogeneousControl(t *testing.T) {
	for _, path := range loopPaths {
		t.Run(string(path), func(t *testing.T) {
			res := runLoopScenario(t, loopScenario{
				name:        "homogeneous_control",
				seed:        1,
				path:        path,
				providers:   loopPeers(loopRequestsInFlight + 2),
				streamStart: 5 * time.Second,
				duration:    loopDuration,
			})
			assertNoStarvation(t, res)
			if res.BusiestPct > loopControlBusiestSharePct {
				t.Errorf("seed %d: busiest provider %s took %.1f%% of requests; limit is %.1f%%",
					res.Seed, res.BusiestID, res.BusiestPct, loopControlBusiestSharePct)
			}
		})
	}
}
