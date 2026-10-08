package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsTrackedBaselineRechecksLinkedHistory(t *testing.T) {
	for _, scenario := range []string{"unsupported_journal", "pretracking_ancestor", "earlier_inventory_gap", "unbound_positive", "conflicting_session_owner"} {
		t.Run(scenario, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				firstSeen := f.start.Add(time.Hour)
				primary := store.MachineObservation{SessionID: "primary", AccountID: "owner", SEKey: "primary-se", At: firstSeen}
				machine := f.observe(t, primary)
				f.consent(t, "primary", "owner", false, firstSeen)
				f.earning(t, "primary", "owner", 70, f.optIn.Add(-48*time.Hour))
				switch scenario {
				case "unsupported_journal":
					if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "delayed", AccountID: "owner", At: f.optIn.Add(-time.Hour)}); !errors.Is(err, earningsfloor.ErrIdentity) {
						t.Fatalf("unbound unsupported declaration = %v", err)
					}
				case "pretracking_ancestor", "earlier_inventory_gap":
					at := f.start
					if scenario == "pretracking_ancestor" {
						at = at.Add(-48 * time.Hour)
					}
					f.observe(t, store.MachineObservation{SessionID: "ancestor", AccountID: "owner", SEKey: "ancestor-se", VerifiedSerial: "ancestor-serial", At: at})
				}
				frozen := f.consent(t, "primary", "owner", true, f.optIn)
				if !frozen.BaselineKnown || frozen.HistoryConflict || frozen.SevenDayEarningsMicroUSD != 70 || frozen.DailyFloorMicroUSD != 11 {
					t.Fatalf("initial automatic baseline = %+v", frozen)
				}
				f.fund(t, 1000)
				paid := f.settle(t, machine.ID, frozen.NextDay)
				if paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 {
					t.Fatalf("initial paid receipt = %+v", paid)
				}
				canonical := machine.ID
				switch scenario {
				case "unsupported_journal":
					canonical = f.observe(t, store.MachineObservation{SessionID: "delayed", AccountID: "owner", SEKey: primary.SEKey, At: f.optIn.Add(time.Hour)}).ID
				case "pretracking_ancestor", "earlier_inventory_gap":
					primary.VerifiedSerial, primary.At = "ancestor-serial", f.optIn.Add(time.Hour)
					canonical = f.observe(t, primary).ID
				case "unbound_positive", "conflicting_session_owner":
					if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "delayed", AccountID: "owner", Supported: true, OptedIn: true, At: f.optIn.Add(-time.Hour)}); !errors.Is(err, earningsfloor.ErrIdentity) {
						t.Fatalf("unbound prior positive = %v", err)
					}
					if scenario == "conflicting_session_owner" {
						f.observe(t, store.MachineObservation{SessionID: "delayed", AccountID: "another-owner", SEKey: "other-se", At: f.optIn.Add(time.Hour)})
					}
				}
				nextDay := paid.Day.AddDate(0, 0, 1)
				// Settlement must discover invalidated tracking proof itself; a
				// preceding list/read is not a prerequisite for the money fence.
				pending := f.settle(t, machine.ID, nextDay)
				if pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 {
					t.Fatalf("invalidated automatic history still paid: %+v", pending)
				}
				listed := readAutopilotRewardEnrollment(t, f, canonical)
				observed := f.consent(t, "primary", "owner", true, f.optIn.Add(2*time.Hour))
				for _, got := range []earningsfloor.Enrollment{listed, observed} {
					if !got.HistoryConflict || !got.BaselineKnown || got.BaselineSource != earningsfloor.TrackedBaseline || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(*frozen.FirstOptInAt) || !got.FirstObservedAt.Equal(frozen.FirstObservedAt) || got.SevenDayEarningsMicroUSD != 70 || got.DailyFloorMicroUSD != 11 || got.BaselineEvidence != frozen.BaselineEvidence || !got.NextDay.Equal(nextDay) {
						t.Fatalf("history hold lost provenance or rewrote frozen fields: %+v", got)
					}
				}
				if replay := f.settle(t, canonical, paid.Day); replay != paid {
					t.Fatalf("new historical evidence rewrote final receipt: %+v, want %+v", replay, paid)
				}
				if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{MachineID: canonical, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "new audit"}); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
					t.Fatalf("invalidated frozen baseline was overwritten by ordinary restore: %v", err)
				}
				pool, err := f.rewards.AutopilotRewardPool(t.Context())
				if err != nil || pool.SpentMicroUSD != 11 || f.backend.GetBalance("owner") != 11 || f.backend.GetWithdrawableBalance("owner") != 11 || len(f.backend.LedgerHistory("owner")) != 1 {
					t.Fatalf("history hold changed money: %+v, %v", pool, err)
				}
			})
		})
	}
}

func TestAutopilotRewardsVerifiedBaselineDoesNotDependOnTrackingProof(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machine := f.observe(t, store.MachineObservation{SessionID: "primary", AccountID: "owner", SEKey: "shared-se", At: f.start.Add(-48 * time.Hour)})
		if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "delayed", AccountID: "owner", At: f.optIn.Add(-time.Hour)}); !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("unbound unsupported declaration = %v", err)
		}
		unknown := f.consent(t, "primary", "owner", true, f.optIn)
		if unknown.BaselineKnown || unknown.BaselineSource != "" {
			t.Fatalf("unknown baseline acquired a provenance: %+v", unknown)
		}
		// Evidence is audit text, not a provenance discriminator. Deliberately
		// matching the automatic evidence string must not turn this into tracked.
		baseline := earningsfloor.Baseline{MachineID: machine.ID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "tracked_inference_history"}
		restored, err := f.rewards.RestoreAutopilotBaseline(t.Context(), baseline)
		if err != nil || !restored.BaselineKnown || restored.BaselineSource != earningsfloor.VerifiedBaseline || restored.BaselineEvidence != baseline.Evidence {
			t.Fatalf("verified baseline provenance = %+v, %v", restored, err)
		}
		if got := f.observe(t, store.MachineObservation{SessionID: "delayed", AccountID: "owner", SEKey: "shared-se", At: f.optIn.Add(time.Hour)}); got.ID != machine.ID {
			t.Fatal("late unsupported session did not bind to the verified machine")
		}
		listed := readAutopilotRewardEnrollment(t, f, machine.ID)
		if listed.HistoryConflict || listed.BaselineSource != earningsfloor.VerifiedBaseline || listed.FirstOptInAt == nil || !listed.FirstOptInAt.Equal(f.optIn) || listed.SevenDayEarningsMicroUSD != 70 {
			t.Fatalf("audited baseline incorrectly depends on complete tracking: %+v", listed)
		}
		f.fund(t, 1000)
		paid := f.settle(t, machine.ID, restored.NextDay)
		if paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 {
			t.Fatalf("old unsupported/pretracking history withheld verified baseline: %+v", paid)
		}
		// Verified history does not override a contradictory, earlier positive
		// declaration from a session now proven to be this very machine.
		conflict := f.consent(t, "delayed", "owner", true, f.optIn.Add(-30*time.Minute))
		if !conflict.HistoryConflict || conflict.BaselineSource != earningsfloor.VerifiedBaseline || conflict.FirstOptInAt == nil || !conflict.FirstOptInAt.Equal(f.optIn) || conflict.SevenDayEarningsMicroUSD != 70 {
			t.Fatalf("verified history ignored a contradictory positive: %+v", conflict)
		}
		nextDay := paid.Day.AddDate(0, 0, 1)
		if pending := f.settle(t, machine.ID, nextDay); pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 || !readAutopilotRewardEnrollment(t, f, machine.ID).NextDay.Equal(nextDay) {
			t.Fatalf("contradicted audited history remained payable: %+v", pending)
		}
		if replay := f.settle(t, machine.ID, paid.Day); replay != paid {
			t.Fatalf("audit conflict rewrote final receipt: %+v, want %+v", replay, paid)
		}
		if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), baseline); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
			t.Fatalf("verified frozen baseline accepted re-import: %v", err)
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 11 || f.backend.GetBalance("owner") != 11 {
			t.Fatalf("verified conflict changed prior credit: %+v, %v", pool, err)
		}
	})
}

func TestAutopilotRewardsRestoreReturnsCurrentHistoryConflict(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machine := f.observe(t, store.MachineObservation{SessionID: "legacy", AccountID: "owner", SEKey: "shared-se", At: f.start.Add(-48 * time.Hour)})
		unknown := f.consent(t, "legacy", "owner", true, f.optIn)
		if unknown.BaselineKnown {
			t.Fatal("legacy fixture unexpectedly has a baseline")
		}
		f.observe(t, store.MachineObservation{SessionID: "earlier", AccountID: "owner", SEKey: "shared-se", At: f.optIn.Add(time.Hour)})
		f.consent(t, "earlier", "owner", true, f.optIn.Add(-2*time.Hour))
		baseline := earningsfloor.Baseline{MachineID: machine.ID, FirstOptInAt: f.optIn.Add(-time.Hour), SevenDayEarningsMicroUSD: 70, Evidence: "audit has a contradictory anchor"}
		restored, err := f.rewards.RestoreAutopilotBaseline(t.Context(), baseline)
		if err != nil || !restored.HistoryConflict {
			t.Fatalf("successful restore returned stale history conflict: %+v, %v", restored, err)
		}
		if !restored.BaselineKnown || restored.BaselineSource != earningsfloor.VerifiedBaseline || restored.FirstOptInAt == nil || !restored.FirstOptInAt.Equal(baseline.FirstOptInAt) || !restored.FirstObservedAt.Equal(unknown.FirstObservedAt) || restored.SevenDayEarningsMicroUSD != 70 || restored.BaselineEvidence != baseline.Evidence || !restored.NextDay.Equal(unknown.NextDay) {
			t.Fatalf("restore changed the supplied audit or participation history: %+v", restored)
		}
		listed := readAutopilotRewardEnrollment(t, f, machine.ID)
		if !listed.HistoryConflict || listed.BaselineSource != restored.BaselineSource || !listed.FirstOptInAt.Equal(*restored.FirstOptInAt) {
			t.Fatalf("restore/list conflict projections disagree: restored=%+v listed=%+v", restored, listed)
		}
		f.fund(t, 1000)
		if receipt := f.settle(t, machine.ID, restored.NextDay); receipt.Status != earningsfloor.HistoryRequired || receipt.AmountMicroUSD != 0 || !readAutopilotRewardEnrollment(t, f, machine.ID).NextDay.Equal(restored.NextDay) {
			t.Fatalf("contradicted restore became payable or advanced: %+v", receipt)
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 0 || f.backend.GetBalance("owner") != 0 {
			t.Fatalf("contradicted restore changed money: %+v, %v", pool, err)
		}
	})
}
