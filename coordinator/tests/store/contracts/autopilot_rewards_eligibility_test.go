package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsDailyUptimeBoundary(t *testing.T) {
	for _, tc := range []struct {
		name    string
		covered time.Duration
		want    string
	}{
		{"exactly_90_percent", 24 * time.Hour * 9 / 10, earningsfloor.Paid},
		{"below_90_percent", 24*time.Hour*9/10 - time.Microsecond, earningsfloor.Ineligible},
	} {
		t.Run(tc.name, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				e := f.enroll(t, "daily", "owner", 70)
				day := e.NextDay
				// Older connection time must not count before this UTC day.
				last := day.Add(tc.covered).Add(-90 * time.Second)
				if err := f.backend.TouchProviderSession(t.Context(), "daily", "", "owner", "rotating-key", last); err != nil {
					t.Fatal(err)
				}
				// A delayed eviction must not add hours after the last heartbeat.
				if err := f.backend.CloseProviderSession(t.Context(), "daily", "stale", day.Add(24*time.Hour)); err != nil {
					t.Fatal(err)
				}
				f.fund(t, 100)
				r := f.settle(t, e.MachineID, day)
				if r.Status != tc.want || (r.Status == earningsfloor.Paid && r.AmountMicroUSD != 11) || (r.Status == earningsfloor.Ineligible && r.AmountMicroUSD != 0) {
					t.Fatalf("daily boundary: %+v", r)
				}
				if replay := f.settle(t, e.MachineID, day); replay != r {
					t.Fatalf("receipt changed on replay: %+v", replay)
				}
			})
		})
	}
}

func TestAutopilotRewardsUptimeUnionsCanonicalSessions(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		e := f.enroll(t, "original", "owner", 70)
		day := e.NextDay
		if err := f.backend.TouchProviderSession(t.Context(), "original", "", "owner", "old-key", day.Add(14*time.Hour)); err != nil {
			t.Fatal(err)
		}
		if err := f.backend.CloseProviderSession(t.Context(), "original", "reconnect", day.Add(14*time.Hour)); err != nil {
			t.Fatal(err)
		}
		alias := f.observe(t, store.MachineObservation{SessionID: "reconnect", AccountID: "owner", SEKey: "original-se", At: day.Add(12 * time.Hour)})
		if alias.ID != e.MachineID {
			t.Fatal("reconnect lost canonical machine")
		}
		f.consent(t, "reconnect", "owner", true, day.Add(12*time.Hour))
		f.fund(t, 100)
		r := f.settle(t, e.MachineID, day)
		if r.Status != earningsfloor.Paid || r.AmountMicroUSD != 11 {
			t.Fatalf("rotation/reconnect lost union coverage: %+v", r)
		}
	})
}

func TestAutopilotRewardsQualificationHistoryDoesNotResetBaseline(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		e := f.enroll(t, "daily", "owner", 70)
		day := e.NextDay
		for _, c := range []earningsfloor.Consent{
			{SessionID: "daily", AccountID: "owner", Supported: true, OptedIn: true, Qualified: false, At: day.Add(23 * time.Hour)},
			{SessionID: "daily", AccountID: "owner", Supported: true, OptedIn: true, Qualified: true, At: day.Add(25 * time.Hour)},
		} {
			if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), c); err != nil {
				t.Fatal(err)
			}
		}
		f.fund(t, 100)
		first := f.settle(t, e.MachineID, day)
		if first.Status != earningsfloor.Ineligible || first.AmountMicroUSD != 0 {
			t.Fatalf("tomorrow's qualification rewrote yesterday: %+v", first)
		}
		second := f.settle(t, e.MachineID, day.AddDate(0, 0, 1))
		if second.Status != earningsfloor.Paid || second.AmountMicroUSD != 11 {
			t.Fatalf("qualification did not recover: %+v", second)
		}
		f.consent(t, "daily", "owner", false, day.Add(50*time.Hour))
		again := f.consent(t, "daily", "owner", true, day.Add(51*time.Hour))
		if !again.FirstOptInAt.Equal(*e.FirstOptInAt) || again.SevenDayEarningsMicroUSD != e.SevenDayEarningsMicroUSD || again.DailyFloorMicroUSD != e.DailyFloorMicroUSD {
			t.Fatalf("qualification or off/on reset baseline: %+v", again)
		}
	})
}
