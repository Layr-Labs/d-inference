package store_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAutopilotRewardsPrunedHistoryIsNeverAssumedComplete(t *testing.T) {
	for _, phase := range []string{"baseline", "daily", "key_association", "unrelated_source", "final_receipt", "baseline_overflow_journal"} {
		t.Run(phase, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				bounded, ok := f.backend.(*memory.MemoryStore)
				if !ok {
					t.Skip("PostgreSQL does not use the bounded in-memory history pruner")
				}
				f.fund(t, 100)
				if phase == "baseline" || phase == "baseline_overflow_journal" {
					f.observe(t, store.MachineObservation{SessionID: "session", AccountID: "owner", SEKey: "se", At: f.start})
					f.consent(t, "session", "owner", false, f.start)
					amount := int64(70)
					if phase == "baseline_overflow_journal" {
						amount = math.MaxInt64
					}
					f.earning(t, "session", "owner", amount, f.optIn.Add(-48*time.Hour))
					if phase == "baseline_overflow_journal" {
						f.earning(t, "session", "owner", 1, f.optIn.Add(-47*time.Hour))
						if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "session", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, At: f.optIn}); err == nil {
							t.Fatal("overflowing baseline was frozen")
						}
					} else {
						f.earning(t, "unrelated", "other", 1, f.optIn.Add(-49*time.Hour))
					}
					bounded.Prune(1)
					at := f.optIn
					if phase == "baseline_overflow_journal" {
						at = at.Add(time.Hour)
					}
					enrollment := f.consent(t, "session", "owner", true, at)
					if enrollment.BaselineKnown || enrollment.FirstOptInAt != nil || !enrollment.FirstObservedAt.Equal(f.optIn) {
						t.Fatalf("pruned/overflowed original history was guessed or re-anchored: %+v", enrollment)
					}
					if receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay); receipt.Status != earningsfloor.HistoryRequired || receipt.AmountMicroUSD != 0 {
						t.Fatalf("missing baseline history paid: %+v", receipt)
					}
					if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{MachineID: enrollment.MachineID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "audited original interval"}); err != nil {
						t.Fatal(err)
					}
					if receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay); receipt.AmountMicroUSD != 11 {
						t.Fatalf("audited repair did not restore exact original baseline: %+v", receipt)
					}
					return
				}
				enrollment := f.enroll(t, "session", "owner", 70)
				switch phase {
				case "daily":
					f.earning(t, "session", "owner", 8, f.optIn.Add(time.Hour))
					f.earning(t, "other", "other", 1, f.optIn)
					bounded.Prune(1)
					f.observe(t, store.MachineObservation{SessionID: "serving", AccountID: "owner", SEKey: "session-se", At: enrollment.NextDay})
					if receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay); receipt.Status != earningsfloor.HistoryRequired || receipt.AmountMicroUSD != 0 || receipt.FloorMicroUSD != 11 {
						t.Fatalf("pruned actual earnings were treated as zero: %+v", receipt)
					}
					f.consent(t, "session", "owner", false, f.optIn.Add(2*time.Hour))
					if receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay); receipt.Status != earningsfloor.OptedOut || receipt.AmountMicroUSD != 0 {
						t.Fatalf("opt-out unnecessarily needs pruned income: %+v", receipt)
					}
					next := enrollment.NextDay.AddDate(0, 0, 1)
					f.consent(t, "session", "owner", true, next.Add(time.Hour))
					if receipt := f.settle(t, enrollment.MachineID, next); receipt.AmountMicroUSD != 11 {
						t.Fatalf("complete later day remained blocked by old history: %+v", receipt)
					}
				case "key_association":
					for _, session := range []string{"session", "other"} {
						if err := f.backend.OpenProviderSession(t.Context(), session, "", "owner"); err != nil {
							t.Fatal(err)
						}
						if err := f.backend.TouchProviderSession(t.Context(), session, "", "owner", session+"-key", time.UnixMicro(f.clock.Load())); err != nil {
							t.Fatal(err)
						}
					}
					if err := f.backend.RecordProviderEarning(&store.ProviderEarning{AccountID: "owner", ProviderKey: "session-key", Model: "model", JobID: "legacy-key-only", AmountMicroUSD: 8, CreatedAt: f.optIn.Add(time.Hour)}); err != nil {
						t.Fatal(err)
					}
					bounded.Prune(1)
					f.observe(t, store.MachineObservation{SessionID: "serving", AccountID: "owner", SEKey: "session-se", At: enrollment.NextDay})
					if receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay); receipt.Status != earningsfloor.HistoryRequired || receipt.AmountMicroUSD != 0 {
						t.Fatalf("pruned key association silently lost income: %+v", receipt)
					}
				case "unrelated_source":
					f.observe(t, store.MachineObservation{SessionID: "other", AccountID: "owner", SEKey: "other-se", At: f.start})
					f.consent(t, "other", "owner", false, f.start)
					f.earning(t, "other", "owner", 1000, f.optIn.Add(time.Hour))
					f.earning(t, "session", "owner", 8, f.optIn.Add(time.Hour))
					bounded.Prune(1)
					f.observe(t, store.MachineObservation{SessionID: "serving", AccountID: "owner", SEKey: "session-se", At: enrollment.NextDay})
					if receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay); receipt.AmountMicroUSD != 3 || receipt.InferenceMicroUSD != 8 {
						t.Fatalf("unrelated pruned machine blocked complete source: %+v", receipt)
					}
				case "final_receipt":
					paid := f.settle(t, enrollment.MachineID, enrollment.NextDay)
					f.earning(t, "other", "other", 1, f.optIn.Add(time.Hour))
					if err := f.backend.Credit("other", 1, store.LedgerAdminCredit, "prune-fixture"); err != nil {
						t.Fatal(err)
					}
					bounded.Prune(1)
					if replay := f.settle(t, enrollment.MachineID, enrollment.NextDay); replay != paid || replay.AmountMicroUSD != 11 {
						t.Fatalf("bounded audit pruning lost final receipt: %+v -> %+v", paid, replay)
					}
					if f.backend.GetBalance("owner") != 11 || f.backend.GetWithdrawableBalance("owner") != 11 {
						t.Fatal("replayed pruned audit double-credited wallet")
					}
				}
				current := readAutopilotRewardEnrollment(t, f, enrollment.MachineID)
				if !current.BaselineKnown || current.SevenDayEarningsMicroUSD != 70 || current.FirstOptInAt == nil || !current.FirstOptInAt.Equal(f.optIn) {
					t.Fatalf("history pruning removed immutable enrollment: %+v", current)
				}
			})
		})
	}
}
