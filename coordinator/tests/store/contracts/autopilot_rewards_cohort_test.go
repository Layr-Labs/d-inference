package store_test

import (
	"encoding/json"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func observeAutopilotCohortMachine(t *testing.T, f *autopilotRewardsFixture, session, account, chip string, memoryGB float64, firstSeen time.Time) store.MachineIdentity {
	t.Helper()
	return f.observe(t, store.MachineObservation{SessionID: session, AccountID: account, SEKey: session + "-se", Chip: chip, MemoryGB: memoryGB, At: firstSeen})
}

func TestAutopilotRewardsCohortUsesExactPeersAndWindow(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		start := f.optIn.Add(-floorpolicy.BaselineDuration)
		peer := observeAutopilotCohortMachine(t, f, "peer", "peer-owner", "Apple M4 Max", 128, f.start)
		// Reconnects and key rotation belong to one canonical peer, rather
		// than making two observations of the same machine count twice.
		alias := f.observe(t, store.MachineObservation{SessionID: "peer-alias", AccountID: "peer-owner", SEKey: "peer-se", Chip: "m4 MAX", MemoryGB: 128, At: f.start.Add(time.Hour)})
		if alias.ID != peer.ID {
			t.Fatal("peer alias did not share its canonical machine")
		}
		f.earning(t, "peer", "peer-owner", 5000, start.Add(-time.Microsecond))
		f.earning(t, "peer", "peer-owner", 21, start)
		f.earning(t, "peer-alias", "peer-owner", 49, f.optIn.Add(-time.Microsecond))
		f.earning(t, "peer-alias", "peer-owner", 5000, f.optIn)
		if err := f.backend.RecordProviderEarning(&store.ProviderEarning{AccountID: "peer-owner", ProviderID: "peer", JobID: "cohort-base", Model: "base_reward", AmountMicroUSD: 5000, CreatedAt: start.Add(time.Hour)}); err != nil {
			t.Fatal(err)
		}
		observeAutopilotCohortMachine(t, f, "second", "second-owner", "M4 Max", 128, start)
		f.earning(t, "second", "second-owner", 141, start.Add(time.Hour))
		for _, mismatch := range []struct {
			session string
			chip    string
			memory  float64
			first   time.Time
		}{
			{"other-tier", "M4 Ultra", 128, f.start},
			{"other-chip", "M3 Max", 128, f.start},
			{"other-memory", "M4 Max", 64, f.start},
			{"unknown-chip", "other M4 Max unknown", 128, f.start},
			{"young-peer", "M4 Max", 128, start.Add(time.Microsecond)},
		} {
			observeAutopilotCohortMachine(t, f, mismatch.session, mismatch.session, mismatch.chip, mismatch.memory, mismatch.first)
			f.earning(t, mismatch.session, mismatch.session, 70000, f.optIn.Add(-time.Hour))
		}
		youngAt := f.optIn.Add(-24 * time.Hour)
		machine := observeAutopilotCohortMachine(t, f, "young", "young-owner", "Apple M4 Max", 128, youngAt)
		f.consent(t, "young", "young-owner", false, youngAt)
		f.earning(t, "young", "young-owner", 90000, f.optIn.Add(-time.Hour))
		got := f.consent(t, "young", "young-owner", true, f.optIn)
		if !got.BaselineKnown || got.HistoryConflict || got.BaselineSource != earningsfloor.CohortBaseline || got.SevenDayEarningsMicroUSD != 105 || got.DailyFloorMicroUSD != 16 || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) {
			t.Fatalf("exact cohort mean baseline = %+v", got)
		}
		var evidence struct {
			floorpolicy.CohortKey
			PeerCount       int       `json:"peer_count"`
			PeerFingerprint string    `json:"peer_fingerprint_sha256"`
			WindowStart     time.Time `json:"window_start"`
			WindowEnd       time.Time `json:"window_end"`
		}
		if err := json.Unmarshal([]byte(got.BaselineEvidence), &evidence); err != nil || evidence.ChipClass != "M4 Max" || evidence.MemoryGB != 128 || evidence.PeerCount != 2 || len(evidence.PeerFingerprint) != 64 || !evidence.WindowStart.Equal(start) || !evidence.WindowEnd.Equal(f.optIn) {
			t.Fatalf("durable cohort evidence = %+v, %v", evidence, err)
		}
		f.earning(t, "peer", "peer-owner", 700000, f.optIn.Add(time.Hour))
		f.consent(t, "young", "young-owner", false, f.optIn.Add(time.Hour))
		again := f.consent(t, "young", "young-owner", true, f.optIn.Add(2*time.Hour))
		listed := readAutopilotRewardEnrollment(t, f, machine.ID)
		for _, frozen := range []earningsfloor.Enrollment{again, listed} {
			if !frozen.BaselineKnown || frozen.FirstOptInAt == nil || !frozen.FirstOptInAt.Equal(*got.FirstOptInAt) || frozen.SevenDayEarningsMicroUSD != got.SevenDayEarningsMicroUSD || frozen.DailyFloorMicroUSD != got.DailyFloorMicroUSD || frozen.BaselineSource != got.BaselineSource || frozen.BaselineEvidence != got.BaselineEvidence {
				t.Fatalf("cohort reset on opt-out/opt-in or reread: %+v", frozen)
			}
		}
	})
}

func TestAutopilotRewardsCohortSevenDayThreshold(t *testing.T) {
	for _, younger := range []bool{false, true} {
		name := "full_seven_days"
		if younger {
			name = "one_microsecond_short"
		}
		t.Run(name, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				start := f.optIn.Add(-floorpolicy.BaselineDuration)
				observeAutopilotCohortMachine(t, f, "peer", "peer-owner", "M4 Max", 128, start)
				f.earning(t, "peer", "peer-owner", 140, start.Add(time.Hour))
				firstSeen := start
				if younger {
					firstSeen = firstSeen.Add(time.Microsecond)
				}
				observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
				f.consent(t, "target", "owner", false, firstSeen)
				f.earning(t, "target", "owner", 70, start.Add(time.Hour))
				got := f.consent(t, "target", "owner", true, f.optIn)
				wantSource, wantSum := earningsfloor.TrackedBaseline, int64(70)
				if younger {
					wantSource, wantSum = earningsfloor.CohortBaseline, 140
				}
				if !got.BaselineKnown || got.BaselineSource != wantSource || got.SevenDayEarningsMicroUSD != wantSum {
					t.Fatalf("seven-day history threshold = %+v, want %s %d", got, wantSource, wantSum)
				}
			})
		})
	}
}

func TestAutopilotRewardsCohortMissingHistoryNeverInventsBaseline(t *testing.T) {
	for _, scenario := range []string{"no_peers", "missing_hardware", "old_unknown_opt_in"} {
		t.Run(scenario, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				if scenario != "no_peers" {
					observeAutopilotCohortMachine(t, f, "peer", "peer-owner", "M4 Max", 128, f.start)
					f.earning(t, "peer", "peer-owner", 140, f.optIn.Add(-time.Hour))
				}
				firstSeen, chip := f.optIn.Add(-time.Hour), "M4 Max"
				if scenario == "missing_hardware" {
					chip = ""
				}
				if scenario == "old_unknown_opt_in" {
					firstSeen = f.start.Add(-48 * time.Hour)
				}
				machine := observeAutopilotCohortMachine(t, f, "target", "owner", chip, 128, firstSeen)
				f.consent(t, "target", "owner", false, firstSeen)
				got := f.consent(t, "target", "owner", true, f.optIn)
				if got.BaselineKnown || got.FirstOptInAt != nil || got.BaselineSource != "" || got.BaselineEvidence != "" || !got.FirstObservedAt.Equal(f.optIn) {
					t.Fatalf("uncertain baseline was invented: %+v", got)
				}
				// New peers and a later opt-in cannot replace the unresolved
				// original snapshot with a more favorable baseline window.
				observeAutopilotCohortMachine(t, f, "late-peer", "late-peer-owner", "M4 Max", 128, f.start)
				f.earning(t, "late-peer", "late-peer-owner", 7000, f.optIn.Add(-time.Hour))
				f.consent(t, "target", "owner", false, f.optIn.Add(time.Hour))
				again := f.consent(t, "target", "owner", true, f.optIn.Add(2*time.Hour))
				for _, pending := range []earningsfloor.Enrollment{again, readAutopilotRewardEnrollment(t, f, machine.ID)} {
					if pending.BaselineKnown || pending.FirstOptInAt != nil || pending.BaselineSource != "" || !pending.FirstObservedAt.Equal(f.optIn) {
						t.Fatalf("uncertain baseline silently recalculated: %+v", pending)
					}
				}
			})
		})
	}
}

func TestAutopilotRewardsCohortMeanDoesNotOverflowAndIncludesKnownZero(t *testing.T) {
	for _, zeroPeer := range []bool{false, true} {
		name := "large_totals"
		if zeroPeer {
			name = "known_zero_peer"
		}
		t.Run(name, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				for _, peer := range []string{"first", "second"} {
					observeAutopilotCohortMachine(t, f, peer, peer+"-owner", "Apple M4 Max", 128, f.start)
					if peer != "second" || !zeroPeer {
						f.earning(t, peer, peer+"-owner", math.MaxInt64, f.optIn.Add(-time.Hour))
					}
				}
				firstSeen := f.optIn.Add(-time.Hour)
				observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
				f.consent(t, "target", "owner", false, firstSeen)
				got := f.consent(t, "target", "owner", true, f.optIn)
				want := int64(math.MaxInt64)
				if zeroPeer {
					want /= 2
				}
				wantFloor, err := floorpolicy.DailyFloor(want)
				if err != nil || !got.BaselineKnown || got.SevenDayEarningsMicroUSD != want || got.DailyFloorMicroUSD != wantFloor {
					t.Fatalf("cohort mean overflowed or excluded a complete zero earner: %+v, want %d, %v", got, want, err)
				}
			})
		})
	}
}

func TestAutopilotRewardsCohortSkipsPrunedPeerHistory(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		bounded, ok := f.backend.(*memory.MemoryStore)
		if !ok {
			t.Skip("PostgreSQL does not prune bounded in-memory history")
		}
		for _, peer := range []string{"pruned", "complete"} {
			observeAutopilotCohortMachine(t, f, peer, peer+"-owner", "M4 Max", 128, f.start)
		}
		f.earning(t, "pruned", "pruned-owner", 7000, f.optIn.Add(-time.Hour))
		f.earning(t, "complete", "complete-owner", 140, f.optIn.Add(-time.Hour))
		bounded.Prune(1)
		firstSeen := f.optIn.Add(-time.Hour)
		observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
		f.consent(t, "target", "owner", false, firstSeen)
		got := f.consent(t, "target", "owner", true, f.optIn)
		if !got.BaselineKnown || got.BaselineSource != earningsfloor.CohortBaseline || got.SevenDayEarningsMicroUSD != 140 {
			t.Fatalf("pruned peer was treated as a complete zero-earning peer: %+v", got)
		}
	})
}

func TestAutopilotRewardsCohortLateConsentConflictPreservesSnapshot(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		observeAutopilotCohortMachine(t, f, "peer", "peer-owner", "M4 Max", 128, f.start)
		f.earning(t, "peer", "peer-owner", 140, f.optIn.Add(-time.Hour))
		firstSeen := f.optIn.Add(-24 * time.Hour)
		machine := observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
		f.consent(t, "target", "owner", false, firstSeen)
		frozen := f.consent(t, "target", "owner", true, f.optIn)
		if !frozen.BaselineKnown || frozen.HistoryConflict || frozen.BaselineSource != earningsfloor.CohortBaseline {
			t.Fatalf("initial cohort history = %+v", frozen)
		}
		// An earlier, unbound positive declaration may be this same owner's
		// machine. Cohort estimation does not weaken the first-ever proof.
		_, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "unbound", AccountID: "owner", Supported: true, OptedIn: true, At: f.optIn.Add(-time.Hour)})
		if !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("earlier unbound declaration = %v", err)
		}
		got := readAutopilotRewardEnrollment(t, f, machine.ID)
		if !got.HistoryConflict || !got.BaselineKnown || got.BaselineSource != frozen.BaselineSource || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(*frozen.FirstOptInAt) || got.SevenDayEarningsMicroUSD != frozen.SevenDayEarningsMicroUSD || got.DailyFloorMicroUSD != frozen.DailyFloorMicroUSD || got.BaselineEvidence != frozen.BaselineEvidence {
			t.Fatalf("late consent conflict ignored or rewrote cohort snapshot: %+v", got)
		}
	})
}

func TestAutopilotRewardsCohortDelayedEnrollmentUsesAnchorHardware(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		for _, peer := range []struct {
			session string
			chip    string
			amount  int64
		}{{"max-peer", "M4 Max", 70}, {"ultra-peer", "M4 Ultra", 140}} {
			observeAutopilotCohortMachine(t, f, peer.session, peer.session, peer.chip, 128, f.start)
			f.earning(t, peer.session, peer.session, peer.amount, f.optIn.Add(-time.Hour))
		}
		firstSeen := f.optIn.Add(-24 * time.Hour)
		observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
		f.consent(t, "target", "owner", false, firstSeen)
		observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Ultra", 128, f.optIn.Add(time.Hour))
		got := f.consent(t, "target", "owner", true, f.optIn)
		if _, bounded := f.backend.(*memory.MemoryStore); bounded {
			if got.BaselineKnown || got.BaselineSource != "" {
				t.Fatalf("bounded inventory invented pre-anchor hardware: %+v", got)
			}
			return
		}
		if !got.BaselineKnown || got.BaselineSource != earningsfloor.CohortBaseline || got.SevenDayEarningsMicroUSD != 70 {
			t.Fatalf("later changed hardware replaced the original cohort: %+v", got)
		}
	})
}

func TestAutopilotRewardsCohortExcludesAmbiguousLegacyPeer(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		for _, peer := range []struct{ session, chip string }{{"matching", "M4 Max"}, {"unrelated", "M3 Max"}} {
			if err := f.backend.OpenProviderSession(t.Context(), peer.session, "", "peer-owner"); err != nil {
				t.Fatal(err)
			}
			if err := f.backend.TouchProviderSession(t.Context(), peer.session, "", "peer-owner", "reused-key", f.start); err != nil {
				t.Fatal(err)
			}
			observeAutopilotCohortMachine(t, f, peer.session, "peer-owner", peer.chip, 128, f.start)
		}
		if err := f.backend.RecordProviderEarning(&store.ProviderEarning{AccountID: "peer-owner", ProviderID: "unmapped-old-session", ProviderKey: "reused-key", JobID: "legacy-cohort", Model: "inference", AmountMicroUSD: 140, CreatedAt: f.optIn.Add(-time.Hour)}); err != nil {
			t.Fatal(err)
		}
		firstSeen := f.optIn.Add(-time.Hour)
		observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
		f.consent(t, "target", "owner", false, firstSeen)
		got := f.consent(t, "target", "owner", true, f.optIn)
		if got.BaselineKnown || got.BaselineSource != "" || got.SevenDayEarningsMicroUSD != 0 {
			t.Fatalf("ambiguous legacy key became cohort earnings or known zero: %+v", got)
		}
	})
}
