package store_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsFirstOptInFreezesExactWindow(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		original := f.observe(t, store.MachineObservation{SessionID: "original", AccountID: "owner", SEKey: "old-se", VerifiedSerial: "serial", At: f.start})
		if got := f.consent(t, "original", "owner", false, f.start); got.MachineID != "" {
			t.Fatalf("explicit opt-out enrolled a machine: %+v", got)
		}
		rotated := f.observe(t, store.MachineObservation{SessionID: "rotated", AccountID: "owner", SEKey: "new-se", VerifiedSerial: "serial", At: f.optIn.Add(-24 * time.Hour)})
		if rotated.ID != original.ID {
			t.Fatal("verified key rotation lost the original machine")
		}
		start := f.optIn.Add(-168 * time.Hour)
		f.earning(t, "original", "owner", 1000, start.Add(-time.Microsecond))
		f.earning(t, "original", "owner", 21, start)
		f.earning(t, "rotated", "owner", 48, f.optIn.Add(-time.Microsecond))
		f.earning(t, "rotated", "owner", 10000, f.optIn)
		if err := f.backend.RecordProviderEarning(&store.ProviderEarning{
			AccountID: "owner", ProviderID: "original", JobID: uniqueID("ordinary-base"),
			Model: "base_reward", AmountMicroUSD: 5000, CreatedAt: f.optIn.Add(-time.Hour),
		}); err != nil {
			t.Fatal(err)
		}
		first := f.consent(t, "rotated", "owner", true, f.optIn)
		if !first.BaselineKnown || first.FirstOptInAt == nil || !first.FirstOptInAt.Equal(f.optIn) || first.SevenDayEarningsMicroUSD != 69 || first.DailyFloorMicroUSD != 10 {
			t.Fatalf("exact [T-168h,T) baseline, rounded once = %+v", first)
		}
		f.earning(t, "rotated", "owner", 20000, f.optIn.Add(time.Hour))
		f.consent(t, "rotated", "owner", false, f.optIn.Add(time.Hour))
		again := f.consent(t, "rotated", "owner", true, f.optIn.Add(2*time.Hour))
		reconnect := f.observe(t, store.MachineObservation{SessionID: "reconnect", AccountID: "owner", SEKey: "new-se", At: f.optIn.Add(3 * time.Hour)})
		if reconnect.ID != original.ID {
			t.Fatal("reconnect lost the rotated alias")
		}
		latest := f.consent(t, "reconnect", "owner", true, f.optIn.Add(3*time.Hour))
		for _, got := range []earningsfloor.Enrollment{again, latest} {
			if got.MachineID != original.ID || !got.BaselineKnown || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) || !got.FirstObservedAt.Equal(first.FirstObservedAt) || got.SevenDayEarningsMicroUSD != 69 || got.DailyFloorMicroUSD != 10 || got.BaselineEvidence != first.BaselineEvidence || !got.NextDay.Equal(first.NextDay) {
				t.Fatalf("re-opt-in or reconnect re-anchored first enrollment: %+v", got)
			}
		}
		f.observe(t, store.MachineObservation{SessionID: "reconnect", AccountID: "owner", SEKey: "new-se", Disconnected: true, At: f.optIn.Add(4 * time.Hour)})
		if got := readAutopilotRewardEnrollment(t, f, original.ID); !got.OptedIn || !got.ObservedAt.Equal(latest.ObservedAt) {
			t.Fatalf("disconnect invented an opt-out: %+v", got)
		}
		_, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{
			MachineID: original.ID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 69, Evidence: first.BaselineEvidence,
		})
		if !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
			t.Fatalf("restore of already tracked baseline = %v", err)
		}
	})
}

func TestAutopilotRewardsDelayedSessionConsentPreservesFirstOptIn(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machine := f.observe(t, store.MachineObservation{SessionID: "first", AccountID: "owner", SEKey: "shared-se", At: f.start})
		f.consent(t, "first", "owner", false, f.start)
		if other := f.observe(t, store.MachineObservation{SessionID: "second", AccountID: "owner", SEKey: "shared-se", At: f.start.Add(time.Microsecond)}); other.ID != machine.ID {
			t.Fatal("sessions did not bind to the same canonical machine")
		}
		f.earning(t, "first", "owner", 70, f.optIn.Add(-48*time.Hour))
		f.earning(t, "second", "owner", 140, f.optIn.Add(time.Hour))
		delayed := earningsfloor.Consent{SessionID: "first", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, At: f.optIn}
		// Registration read loops run independently: a later opt-out can reach
		// the store before the other session's original accepted opt-in.
		optOutAt := f.optIn.Add(time.Second)
		if got := f.consent(t, "second", "owner", false, optOutAt); got.MachineID != "" {
			t.Fatalf("opt-out created an enrollment before the delayed positive: %+v", got)
		}
		first, err := f.rewards.ObserveAutopilotConsent(t.Context(), delayed)
		if err != nil || first.MachineID != machine.ID || !first.BaselineKnown || first.FirstOptInAt == nil || !first.FirstOptInAt.Equal(f.optIn) || !first.FirstObservedAt.Equal(f.optIn) || first.SevenDayEarningsMicroUSD != 70 || first.DailyFloorMicroUSD != 11 || first.OptedIn || !first.ObservedAt.Equal(optOutAt) {
			t.Fatalf("delayed first opt-in was lost or replaced current consent: %+v, %v", first, err)
		}
		again := f.consent(t, "first", "owner", true, f.optIn.Add(2*time.Hour))
		if !again.BaselineKnown || again.FirstOptInAt == nil || !again.FirstOptInAt.Equal(f.optIn) || !again.FirstObservedAt.Equal(f.optIn) || again.SevenDayEarningsMicroUSD != 70 || again.DailyFloorMicroUSD != 11 || !again.OptedIn || !again.ObservedAt.Equal(f.optIn.Add(2*time.Hour)) {
			t.Fatalf("later opt-in re-anchored the delayed first baseline: %+v", again)
		}
		day := first.NextDay
		latestAt := day.Add(49 * time.Hour)
		f.consent(t, "first", "owner", true, latestAt)
		got := f.consent(t, "second", "owner", false, day.Add(47*time.Hour))
		if !got.OptedIn || !got.ObservedAt.Equal(latestAt) {
			t.Fatalf("delayed cross-session history regressed current consent: %+v", got)
		}
		f.fund(t, 1000)
		for i, want := range []string{earningsfloor.Zero, earningsfloor.OptedOut, earningsfloor.Paid} {
			receipt := f.settle(t, machine.ID, day.AddDate(0, 0, i))
			if receipt.Status != want || (want == earningsfloor.Paid && receipt.AmountMicroUSD != 11) || (want != earningsfloor.Paid && receipt.AmountMicroUSD != 0) {
				t.Fatalf("unfinalized day %d ignored delayed cross-session history: %+v", i, receipt)
			}
		}
	})
}

func TestAutopilotRewardsLateEarlierConsentFlagsFrozenHistory(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machine := f.observe(t, store.MachineObservation{SessionID: "earlier", AccountID: "owner", SEKey: "shared-se", At: f.start})
		f.consent(t, "earlier", "owner", false, f.start)
		if other := f.observe(t, store.MachineObservation{SessionID: "later", AccountID: "owner", SEKey: "shared-se", At: f.start}); other.ID != machine.ID {
			t.Fatal("sessions did not share the verified identity")
		}
		f.consent(t, "later", "owner", false, f.start)
		// Both baseline earnings precede the anchor's UTC day, so the first
		// receipt actually pays money rather than being zeroed by same-day work.
		earlierAt := f.optIn.Truncate(24 * time.Hour).Add(22*time.Hour + 30*time.Minute)
		anchor := earlierAt.Add(2 * time.Hour)
		f.earning(t, "earlier", "owner", 70, earlierAt.Add(-48*time.Hour))
		f.earning(t, "later", "owner", 70, earlierAt.Add(time.Hour))
		frozen := f.consent(t, "later", "owner", true, anchor)
		if !frozen.BaselineKnown || frozen.HistoryConflict || frozen.FirstOptInAt == nil || !frozen.FirstOptInAt.Equal(anchor) || frozen.SevenDayEarningsMicroUSD != 140 || frozen.DailyFloorMicroUSD != 22 {
			t.Fatalf("initial frozen baseline = %+v", frozen)
		}
		f.fund(t, 1000)
		paid := f.settle(t, machine.ID, frozen.NextDay)
		if paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 22 {
			t.Fatalf("pre-conflict receipt = %+v", paid)
		}
		f.clock.Add(int64(time.Hour / time.Microsecond))
		conflicted := f.consent(t, "earlier", "owner", true, earlierAt)
		nextDay := paid.Day.AddDate(0, 0, 1)
		for _, got := range []earningsfloor.Enrollment{conflicted, readAutopilotRewardEnrollment(t, f, machine.ID)} {
			if !got.HistoryConflict || !got.BaselineKnown || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(anchor) || !got.FirstObservedAt.Equal(anchor) || got.SevenDayEarningsMicroUSD != 140 || got.DailyFloorMicroUSD != 22 || got.BaselineEvidence != frozen.BaselineEvidence || !got.OptedIn || !got.ObservedAt.Equal(anchor) || !got.NextDay.Equal(nextDay) {
				t.Fatalf("earlier journal evidence was hidden or rewrote frozen history: %+v", got)
			}
		}
		if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{MachineID: machine.ID, FirstOptInAt: earlierAt, SevenDayEarningsMicroUSD: 70, Evidence: "earlier-consent-audit"}); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
			t.Fatalf("conflicted frozen baseline accepted ordinary restore: %v", err)
		}
		if replay := f.settle(t, machine.ID, paid.Day); replay != paid {
			t.Fatalf("history conflict changed a final receipt: %+v, want %+v", replay, paid)
		}
		for _, optedOut := range []bool{false, true} {
			if optedOut {
				f.consent(t, "later", "owner", false, nextDay.Add(time.Hour))
			}
			pending := f.settle(t, machine.ID, nextDay)
			if pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 {
				t.Fatalf("conflicted unpaid day became final (opted_out=%v): %+v", optedOut, pending)
			}
			if got := readAutopilotRewardEnrollment(t, f, machine.ID); !got.HistoryConflict || !got.NextDay.Equal(nextDay) {
				t.Fatalf("pending conflict advanced or disappeared: %+v", got)
			}
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 22 || f.backend.GetBalance("owner") != 22 {
			t.Fatalf("history conflict paid again or clawed back credit: pool=%+v, %v, balance=%d", pool, err, f.backend.GetBalance("owner"))
		}
	})
}

func TestAutopilotRewardsIncompleteConsentHistoryStaysUnknown(t *testing.T) {
	for _, scenario := range []string{"pre_tracking_overwritten", "late_first_declaration", "unsupported_without_off_proof", "unsupported_after_explicit_off"} {
		t.Run(scenario, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				firstSeen := f.start
				if scenario == "pre_tracking_overwritten" {
					firstSeen = f.start.Add(-48 * time.Hour)
				}
				machine := f.observe(t, store.MachineObservation{SessionID: "machine", AccountID: "owner", SEKey: "se", At: firstSeen})
				switch scenario {
				case "pre_tracking_overwritten", "unsupported_after_explicit_off":
					f.consent(t, "machine", "owner", false, firstSeen)
				case "late_first_declaration":
					f.consent(t, "machine", "owner", false, firstSeen.Add(time.Microsecond))
				}
				if strings.HasPrefix(scenario, "unsupported_") {
					at := firstSeen
					if scenario == "unsupported_after_explicit_off" {
						at = f.optIn.Add(-time.Hour)
					}
					got, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "machine", AccountID: "owner", At: at})
					if err != nil || got.MachineID != "" {
						t.Fatalf("unsupported declaration = %+v, %v", got, err)
					}
				}
				// Replacing the inventory observation must not replace first_seen.
				f.observe(t, store.MachineObservation{SessionID: "machine", AccountID: "owner", SEKey: "se", At: f.optIn.Add(-time.Microsecond)})
				f.earning(t, "machine", "owner", 70, f.optIn.Add(-time.Hour))
				first := f.consent(t, "machine", "owner", true, f.optIn)
				f.consent(t, "machine", "owner", false, f.optIn.Add(time.Hour))
				again := f.consent(t, "machine", "owner", true, f.optIn.Add(2*time.Hour))
				for _, got := range []earningsfloor.Enrollment{first, again, readAutopilotRewardEnrollment(t, f, machine.ID)} {
					if got.MachineID != machine.ID || got.BaselineKnown || got.FirstOptInAt != nil || got.SevenDayEarningsMicroUSD != 0 || got.DailyFloorMicroUSD != 0 || got.BaselineEvidence != "" || !got.FirstObservedAt.Equal(f.optIn) || !got.NextDay.Equal(f.optIn.Truncate(24*time.Hour)) {
						t.Fatalf("incomplete history was auto-anchored: %+v", got)
					}
				}
			})
		})
	}
}

func TestAutopilotRewardsRestoreDoesNotBackdateConsent(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machine := f.observe(t, store.MachineObservation{SessionID: "legacy", AccountID: "owner", SEKey: "se", At: f.start.Add(-48 * time.Hour)})
		unknown := f.consent(t, "legacy", "owner", true, f.optIn)
		f.fund(t, 1000)
		pending := f.settle(t, machine.ID, unknown.NextDay)
		if pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 || !readAutopilotRewardEnrollment(t, f, machine.ID).NextDay.Equal(unknown.NextDay) {
			t.Fatalf("missing history did not leave the day pending: %+v", pending)
		}
		baseline := earningsfloor.Baseline{MachineID: machine.ID, FirstOptInAt: f.optIn.Add(-10 * 24 * time.Hour), SevenDayEarningsMicroUSD: 140, Evidence: strings.Repeat("e", 1024)}
		for _, scenario := range []string{"negative_sum", "empty_evidence", "blank_evidence", "oversized_evidence", "missing_first_opt_in", "after_first_observed"} {
			invalid := baseline
			switch scenario {
			case "negative_sum":
				invalid.SevenDayEarningsMicroUSD = -1
			case "empty_evidence":
				invalid.Evidence = ""
			case "blank_evidence":
				invalid.Evidence = " \t\n"
			case "oversized_evidence":
				invalid.Evidence += "e"
			case "missing_first_opt_in":
				invalid.FirstOptInAt = time.Time{}
			case "after_first_observed":
				invalid.FirstOptInAt = f.optIn.Add(time.Microsecond)
			}
			if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), invalid); err == nil {
				t.Fatalf("accepted invalid baseline: %s", scenario)
			}
			if got := readAutopilotRewardEnrollment(t, f, machine.ID); got.BaselineKnown || got.FirstOptInAt != nil || !got.NextDay.Equal(unknown.NextDay) {
				t.Fatalf("%s mutated missing history: %+v", scenario, got)
			}
		}
		f.consent(t, "legacy", "owner", false, f.optIn.Add(time.Hour))
		optedOut := f.settle(t, machine.ID, unknown.NextDay)
		if optedOut.Status != earningsfloor.OptedOut || optedOut.AmountMicroUSD != 0 {
			t.Fatalf("opt-out with unknown history was not final: %+v", optedOut)
		}
		restored, err := f.rewards.RestoreAutopilotBaseline(t.Context(), baseline)
		if err != nil || !restored.BaselineKnown || restored.FirstOptInAt == nil || !restored.FirstOptInAt.Equal(baseline.FirstOptInAt) || restored.SevenDayEarningsMicroUSD != 140 || restored.DailyFloorMicroUSD != 22 || restored.BaselineEvidence != baseline.Evidence || restored.OptedIn || !restored.FirstObservedAt.Equal(f.optIn) || !restored.NextDay.Equal(unknown.NextDay.AddDate(0, 0, 1)) {
			t.Fatalf("restore rewrote participation history: %+v, %v", restored, err)
		}
		if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), baseline); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
			t.Fatalf("exact frozen baseline retry = %v", err)
		}
		if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), machine.ID, unknown.NextDay.AddDate(0, 0, -1)); !errors.Is(err, earningsfloor.ErrDayOrder) {
			t.Fatalf("backfill created earlier day eligibility: %v", err)
		}
		if replay := f.settle(t, machine.ID, unknown.NextDay); replay != optedOut {
			t.Fatalf("backfill rewrote an opted-out receipt: %+v, want %+v", replay, optedOut)
		}
		if next := f.settle(t, machine.ID, restored.NextDay); next.Status != earningsfloor.OptedOut || next.AmountMicroUSD != 0 {
			t.Fatalf("backfill invented positive consent: %+v", next)
		}
	})
}

func TestAutopilotRewardsConsentUTCDeadline(t *testing.T) {
	for _, before := range []bool{true, false} {
		name := "at_day_end"
		if before {
			name = "before_day_end"
		}
		t.Run(name, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				enrollment := f.enroll(t, "machine", "owner", 70)
				end := enrollment.NextDay.AddDate(0, 0, 1)
				at := end
				if before {
					at = at.Add(-time.Microsecond)
				}
				f.consent(t, "machine", "owner", false, at)
				f.fund(t, 1000)
				wantStatus, wantAmount := earningsfloor.Paid, int64(11)
				if before {
					wantStatus, wantAmount = earningsfloor.OptedOut, 0
				}
				if got := f.settle(t, enrollment.MachineID, enrollment.NextDay); got.Status != wantStatus || got.AmountMicroUSD != wantAmount {
					t.Fatalf("consent at %s changed the wrong UTC day: %+v", at, got)
				}
				if got := f.settle(t, enrollment.MachineID, end); got.Status != earningsfloor.OptedOut || got.AmountMicroUSD != 0 {
					t.Fatalf("opt-out was lost on the following day: %+v", got)
				}
			})
		})
	}
}

func TestAutopilotRewardsConsentWatermarksAcrossAliases(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		first := f.enroll(t, "positive", "owner", 70)
		alias := f.observe(t, store.MachineObservation{SessionID: "negative", AccountID: "owner", SEKey: "negative-se", VerifiedSerial: "merged", At: f.start})
		f.consent(t, "negative", "owner", false, f.start)
		day := first.NextDay
		for _, at := range []time.Time{day.Add(17 * time.Hour), day.Add(32 * time.Hour), day.Add(44 * time.Hour)} {
			if got := f.consent(t, "positive", "owner", true, at); !got.ObservedAt.Equal(at) || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) {
				t.Fatalf("same-value checkpoint lost its watermark or first instant: %+v", got)
			}
		}
		// The false rows are newer than each true row's first timestamp, but
		// older than its same-day last observation. Event-start ordering is wrong.
		f.consent(t, "negative", "owner", false, day.Add(15*time.Hour))
		f.consent(t, "negative", "owner", false, day.Add(39*time.Hour))
		unsupportedAt := day.Add(49 * time.Hour)
		if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "positive", AccountID: "owner", At: unsupportedAt}); err != nil {
			t.Fatal(err)
		}
		merged := f.observe(t, store.MachineObservation{SessionID: "positive", AccountID: "owner", SEKey: "positive-se", VerifiedSerial: "merged", At: day.Add(50 * time.Hour)})
		if merged.ID != alias.ID {
			t.Fatal("consent fixture did not merge both sessions")
		}
		// Stale deliveries within one session cannot move that session's
		// watermark backwards or rewrite its already accepted history.
		for _, optedIn := range []bool{false, true} {
			got := f.consent(t, "positive", "owner", optedIn, day.Add(47*time.Hour))
			if got.OptedIn || !got.ObservedAt.Equal(unsupportedAt) {
				t.Fatalf("stale same-session declaration was accepted: %+v", got)
			}
		}
		future := time.UnixMicro(f.clock.Load()).Add(time.Microsecond)
		if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "positive", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, At: future}); err == nil {
			t.Fatal("accepted a future server observation")
		}
		if got := readAutopilotRewardEnrollment(t, f, merged.ID); got.OptedIn || !got.ObservedAt.Equal(unsupportedAt) {
			t.Fatalf("unsupported or rejected future consent lost its state: %+v", got)
		}
		f.fund(t, 1000)
		for i, want := range []string{earningsfloor.Paid, earningsfloor.Paid, earningsfloor.OptedOut} {
			got := f.settle(t, merged.ID, day.AddDate(0, 0, i))
			if got.Status != want || (want == earningsfloor.Paid && got.AmountMicroUSD != 11) || (want == earningsfloor.OptedOut && got.AmountMicroUSD != 0) {
				t.Fatalf("day %d used current state or another day's watermark: %+v", i, got)
			}
		}
	})
}

func readAutopilotRewardEnrollment(t *testing.T, f *autopilotRewardsFixture, machineID string) earningsfloor.Enrollment {
	t.Helper()
	rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.MachineID == machineID {
			return row
		}
	}
	t.Fatalf("enrollment %s missing from %+v", machineID, rows)
	return earningsfloor.Enrollment{}
}
