package accounts_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestErasureOutboxResendContactRequiresOperator(t *testing.T) {
	for _, tc := range []struct {
		name string
		mock bool
	}{
		{name: "live billing"},
		{name: "mock billing", mock: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fx := newOutboxFixture(t, tc.mock)
			account := fx.scrub(t, outboxSeed{})
			before := fx.row(t, account, store.ErasureTargetResendContact)
			if before.State != store.ErasureOutboxPending || before.ExternalID != account+"@example.com" {
				t.Fatalf("scrub did not queue the contact: %+v", before)
			}
			fx.pass(t, account)
			row := fx.row(t, account, store.ErasureTargetResendContact)
			if row.State != store.ErasureOutboxManualAction || row.LastError != "Resend contact removal requires operator confirmation" {
				t.Fatalf("contact removal did not require operator confirmation: %+v", row)
			}
			if row.ExternalID != before.ExternalID || !row.HasExternalID || row.DoneAt != nil || row.Attempts != 1 {
				t.Fatalf("manual obligation was not retained: %+v", row)
			}
			if fx.stripe.total() != 0 {
				t.Fatal("manual contact removal called Stripe")
			}
		})
	}
}
