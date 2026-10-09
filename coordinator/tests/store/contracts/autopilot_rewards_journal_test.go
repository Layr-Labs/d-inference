package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotConsentJournalDefersBaselineAndPreservesFirstDeclaration(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		journal, ok := store.As[store.AutopilotConsentJournal](store.NewCached(f.backend, store.DefaultCacheConfig()))
		if !ok {
			t.Fatal("consent journal is unavailable through the store decorator")
		}
		observeAutopilotCohortMachine(t, f, "peer", "peer-owner", "M4 Max", 128, f.start)
		f.earning(t, "peer", "peer-owner", 70, f.optIn.Add(-time.Hour))
		firstSeen := f.optIn.Add(-24 * time.Hour)
		machine := observeAutopilotCohortMachine(t, f, "target", "owner", "M4 Max", 128, firstSeen)
		f.consent(t, "target", "owner", false, firstSeen)
		consent := earningsfloor.Consent{SessionID: "target", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, Chip: "M4 Max", MemoryGB: 128, At: f.optIn}
		if err := journal.RecordAutopilotConsent(t.Context(), consent); err != nil {
			t.Fatal(err)
		}
		// The receive-time write did not freeze money. The worker's first
		// materialization sees all earnings committed before that operation.
		f.earning(t, "peer", "peer-owner", 70, f.optIn.Add(-time.Hour))
		got := readAutopilotRewardEnrollment(t, f, machine.ID)
		if !got.BaselineKnown || got.BaselineSource != earningsfloor.CohortBaseline || got.SevenDayEarningsMicroUSD != 140 || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(f.optIn) {
			t.Fatalf("journal materialized early or lost the original anchor: %+v", got)
		}
		f.earning(t, "peer", "peer-owner", 7000, f.optIn.Add(-time.Hour))
		consent.OptedIn, consent.At = false, f.optIn.Add(time.Hour)
		if err := journal.RecordAutopilotConsent(t.Context(), consent); err != nil {
			t.Fatal(err)
		}
		consent.OptedIn, consent.At = true, f.optIn.Add(2*time.Hour)
		if err := journal.RecordAutopilotConsent(t.Context(), consent); err != nil {
			t.Fatal(err)
		}
		frozen := readAutopilotRewardEnrollment(t, f, machine.ID)
		if frozen.SevenDayEarningsMicroUSD != got.SevenDayEarningsMicroUSD || frozen.BaselineEvidence != got.BaselineEvidence || frozen.FirstOptInAt == nil || !frozen.FirstOptInAt.Equal(*got.FirstOptInAt) {
			t.Fatalf("later journal events reset the frozen baseline: %+v", frozen)
		}
	})
}

func TestAutopilotConsentJournalUnboundSuccessDoesNotHideRejectedWrites(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		journal, ok := store.As[store.AutopilotConsentJournal](f.backend)
		if !ok {
			t.Fatal("consent journal is unavailable")
		}
		valid := earningsfloor.Consent{SessionID: "unbound", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, Chip: "M4 Max", MemoryGB: 128, At: f.optIn}
		if err := journal.RecordAutopilotConsent(t.Context(), valid); err != nil {
			t.Fatalf("successful unbound persistence must not return an enrollment error: %v", err)
		}
		otherOwner := valid
		otherOwner.AccountID, otherOwner.At = "other", f.optIn.Add(time.Hour)
		if err := journal.RecordAutopilotConsent(t.Context(), otherOwner); !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("journal accepted a session owner change: %v", err)
		}
		invalid := valid
		invalid.SessionID = ""
		if err := journal.RecordAutopilotConsent(t.Context(), invalid); !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("journal hid invalid input: %v", err)
		}
		canceled, cancel := context.WithCancel(t.Context())
		cancel()
		if err := journal.RecordAutopilotConsent(canceled, valid); !errors.Is(err, context.Canceled) {
			t.Fatalf("journal hid cancellation: %v", err)
		}
		machine := observeAutopilotCohortMachine(t, f, "unbound", "owner", "M4 Max", 128, f.optIn)
		got := readAutopilotRewardEnrollment(t, f, machine.ID)
		if got.AccountID != "owner" || !got.FirstObservedAt.Equal(valid.At) || !got.OptedIn || !got.ObservedAt.Equal(valid.At) {
			t.Fatalf("rejected writes altered durable unbound evidence: %+v", got)
		}
		if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: "another-unbound", AccountID: "owner", Supported: true, At: f.optIn}); !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("immediate Observe lost its unbound enrollment result: %v", err)
		}
	})
}
