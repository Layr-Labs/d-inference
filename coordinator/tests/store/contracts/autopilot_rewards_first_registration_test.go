package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsFirstRegistrationUsesOriginalConsentHardware(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		f.observe(t, store.MachineObservation{SessionID: "peer", AccountID: "peer-owner", SEKey: "peer-se", Chip: "Apple M4 Max", MemoryGB: 64, At: f.start})
		f.earning(t, "peer", "peer-owner", 70, f.optIn.Add(-48*time.Hour))
		original := earningsfloor.Consent{SessionID: "new", AccountID: "owner", Supported: true, OptedIn: true, Chip: "Apple M4 Max", MemoryGB: 64, At: f.optIn}
		if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), original); !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("unbound first registration: %v", err)
		}
		// Inventory necessarily lands after the registration was read. Later
		// hardware must neither hide nor replace the original enrollment cohort.
		m := f.observe(t, store.MachineObservation{SessionID: "new", AccountID: "owner", SEKey: "new-se", Chip: "Apple M5 Ultra", MemoryGB: 128, At: f.optIn.Add(time.Second)})
		e := readAutopilotRewardEnrollment(t, f, m.ID)
		if !e.BaselineKnown || e.BaselineSource != earningsfloor.CohortBaseline || !e.FirstOptInAt.Equal(f.optIn) || !e.FirstObservedAt.Equal(f.optIn) || e.SevenDayEarningsMicroUSD != 70 || e.DailyFloorMicroUSD != 11 {
			t.Fatalf("first registration lost original hardware/anchor: %+v", e)
		}
		original.At = f.optIn.Add(time.Hour)
		original.Qualified = true
		original.Chip = "Apple M5 Ultra"
		original.MemoryGB = 128
		again, err := f.rewards.ObserveAutopilotConsent(t.Context(), original)
		if err != nil || again.HistoryConflict || !again.FirstOptInAt.Equal(f.optIn) || again.BaselineEvidence != e.BaselineEvidence || again.SevenDayEarningsMicroUSD != 70 {
			t.Fatalf("later ready declaration changed original cohort: %+v %v", again, err)
		}
	})
}
