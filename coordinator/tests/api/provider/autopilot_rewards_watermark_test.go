package provider_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAutopilotConsentCaptureUnboundRepeatAdvancesMergedDayState(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.register(t, savedConsent(true))
	f.heartbeat(t, savedConsent(true), 1)
	calls := f.store.snapshot()
	if len(calls) != 3 || calls[1].consent != calls[0].consent || !calls[2].consent.At.After(calls[0].consent.At) {
		t.Fatalf("unbound repeat did not journal both original and fresh server instants: %+v", calls)
	}
	for _, call := range calls {
		if !errors.Is(call.err, earningsfloor.ErrIdentity) || !call.consent.OptedIn || !call.consent.Supported {
			t.Fatalf("unexpected unbound declaration: %+v", call)
		}
	}
	// Replay the actual captured declarations at deterministic server-test
	// dates to exercise UTC boundaries without a clock override in the socket
	// protocol. The real store must retain both the original and new-day At.
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	st := memory.NewMemory(store.Config{Now: func() time.Time { return now }})
	day1 := now.AddDate(0, 0, 1)
	day2, day3, day4 := day1.AddDate(0, 0, 1), day1.AddDate(0, 0, 2), day1.AddDate(0, 0, 3)
	now = day4.Add(12 * time.Hour)
	first, latest := calls[0].consent, calls[2].consent
	first.At, latest.At = day1.Add(time.Hour), day3.Add(time.Hour)
	if _, err := st.ObserveAutopilotConsent(t.Context(), first); !errors.Is(err, earningsfloor.ErrIdentity) {
		t.Fatalf("day-one unbound declaration: %v", err)
	}
	machine, err := st.ObserveMachine(t.Context(), store.MachineObservation{
		SessionID: "bound-session", AccountID: first.AccountID, SEKey: "same-machine", At: day2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{
		SessionID: "bound-session", AccountID: first.AccountID, Supported: true, OptedIn: false, At: day2.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveAutopilotConsent(t.Context(), latest); !errors.Is(err, earningsfloor.ErrIdentity) {
		t.Fatalf("day-three unbound checkpoint: %v", err)
	}
	bound, err := st.ObserveMachine(t.Context(), store.MachineObservation{
		SessionID: first.SessionID, AccountID: first.AccountID, SEKey: "same-machine", At: day4,
	})
	if err != nil || bound.ID != machine.ID {
		t.Fatalf("late binding did not resolve the same machine: %+v, %v", bound, err)
	}
	// These captured sessions have no mature hardware cohort. Restore an
	// explicitly verified baseline so settlement can evaluate day-state history
	// independently from the intentionally unavailable baseline evidence.
	if _, err := st.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{
		MachineID: machine.ID, FirstOptInAt: first.At, Evidence: "verified fixture first consent and zero inference earnings",
	}); err != nil {
		t.Fatal(err)
	}
	rows, err := st.AutopilotRewardEnrollments(t.Context(), "", 100)
	if err != nil || len(rows) != 1 || !rows[0].OptedIn || !rows[0].ObservedAt.Equal(latest.At) || rows[0].FirstOptInAt == nil || !rows[0].FirstOptInAt.Equal(first.At) {
		t.Fatalf("late alias binding lost day-three state or reanchored first opt-in: %+v, %v", rows, err)
	}
	for _, expectation := range []struct {
		day    time.Time
		status string
	}{{day1, earningsfloor.Ineligible}, {day2, earningsfloor.OptedOut}, {day3, earningsfloor.Ineligible}} {
		receipt, err := st.SettleAutopilotRewardDay(t.Context(), machine.ID, expectation.day)
		if err != nil || receipt.Status != expectation.status {
			t.Fatalf("day %v state = %+v, %v; want %s", expectation.day, receipt, err, expectation.status)
		}
	}
}
