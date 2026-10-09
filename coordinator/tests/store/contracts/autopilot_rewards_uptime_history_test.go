package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAutopilotRewardsPrunedUptimeRemainsPending(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		bounded, ok := f.backend.(*memory.MemoryStore)
		if !ok {
			t.Skip("PostgreSQL retains provider-session evidence")
		}
		e := f.enroll(t, "online", "owner", 70)
		if err := f.backend.OpenProviderSession(t.Context(), "unrelated", "", "other"); err != nil {
			t.Fatal(err)
		}
		bounded.Prune(1)
		f.fund(t, 100)
		pending := f.settle(t, e.MachineID, e.NextDay)
		if pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 {
			t.Fatalf("lost uptime finalized as low uptime: %+v", pending)
		}
		if current := readAutopilotRewardEnrollment(t, f, e.MachineID); !current.NextDay.Equal(e.NextDay) {
			t.Fatalf("missing uptime advanced cursor: %+v", current)
		}
		// Retained independent >=90% coverage proves eligibility even though an
		// overlapping old session was pruned. Missing rows cannot lower the union.
		f.observe(t, store.MachineObservation{SessionID: "overlap", AccountID: "owner", SEKey: "online-se", At: e.NextDay})
		paid := f.settle(t, e.MachineID, e.NextDay)
		if paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 {
			t.Fatalf("proven retained uptime did not recover pending day: %+v", paid)
		}
		if replay := f.settle(t, e.MachineID, e.NextDay); replay != paid {
			t.Fatalf("recovery replay changed money: %+v", replay)
		}
	})
}
