package pricing

import (
	"testing"

	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/store"
)

func TestDiscountBPSFromPercentValidation(t *testing.T) {
	tests := []struct {
		name    string
		percent float64
		want    int
		wantErr bool
	}{
		{name: "zero", percent: 0, want: 0},
		{name: "fractional", percent: 12.34, want: 1234},
		{name: "cap", percent: 90, want: 9000},
		{name: "negative", percent: -0.01, wantErr: true},
		{name: "above cap", percent: 90.01, wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := DiscountBPSFromPercent(tc.percent)
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatalf("DiscountBPSFromPercent: %v", err)
			}
			if got != tc.want {
				t.Fatalf("bps = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestEffectiveModelPriceDiscountPrecedence(t *testing.T) {
	st := store.NewMemory("")
	const model = "discount-model"
	if err := st.SetModelPrice("platform", model, 1_000_000, 2_000_000); err != nil {
		t.Fatalf("SetModelPrice: %v", err)
	}
	mustSet := func(providerKey, model string, bps int) {
		t.Helper()
		if err := st.SetProviderDiscount("acct-1", providerKey, model, bps); err != nil {
			t.Fatalf("SetProviderDiscount(%q,%q): %v", providerKey, model, err)
		}
	}
	mustSet("", "", 1000)
	mustSet("", model, 2000)
	mustSet("serial-1", "", 3000)
	mustSet("serial-1", model, 4000)

	tests := []struct {
		name        string
		accountID   string
		providerKey string
		model       string
		wantScope   string
		wantInput   int64
		wantOutput  int64
	}{
		{
			name:        "machine model wins",
			accountID:   "acct-1",
			providerKey: "serial-1",
			model:       model,
			wantScope:   "machine_model",
			wantInput:   600_000,
			wantOutput:  1_200_000,
		},
		{
			name:        "machine global beats account model",
			accountID:   "acct-1",
			providerKey: "serial-1",
			model:       "other-model",
			wantScope:   "machine_global",
		},
		{
			name:      "account model beats account global",
			accountID: "acct-1",
			model:     model,
			wantScope: "account_model",
			wantInput: 800_000,
		},
		{
			name:      "account global fallback",
			accountID: "acct-1",
			model:     "other-model",
			wantScope: "account_global",
		},
		{
			name:      "platform when account missing",
			accountID: "acct-2",
			model:     model,
			wantScope: "",
			wantInput: 1_000_000,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ep := EffectiveModelPrice(st, tc.accountID, tc.providerKey, tc.model)
			if ep.DiscountScope != tc.wantScope {
				t.Fatalf("scope = %q, want %q", ep.DiscountScope, tc.wantScope)
			}
			if tc.wantInput != 0 && ep.InputPrice != tc.wantInput {
				t.Fatalf("input price = %d, want %d", ep.InputPrice, tc.wantInput)
			}
			if tc.wantOutput != 0 && ep.OutputPrice != tc.wantOutput {
				t.Fatalf("output price = %d, want %d", ep.OutputPrice, tc.wantOutput)
			}
		})
	}
}

func TestCalculateCostDiscountAndMinimumCharge(t *testing.T) {
	st := store.NewMemory("")
	const model = "billing-discount-model"
	if err := st.SetModelPrice("platform", model, 1_000_000, 2_000_000); err != nil {
		t.Fatalf("SetModelPrice: %v", err)
	}
	if err := st.SetProviderDiscount("acct-1", "", model, 5000); err != nil {
		t.Fatalf("SetProviderDiscount: %v", err)
	}

	got := CalculateCost(st, "acct-1", "", model, 1_000, 1_000)
	want := int64(1_500)
	if got != want {
		t.Fatalf("CalculateCost = %d, want %d", got, want)
	}
	if payout := payments.ProviderPayout(got); payout != 1425 {
		t.Fatalf("ProviderPayout(discounted charge) = %d, want 1425", payout)
	}

	min := CalculateCost(st, "acct-1", "", model, 1, 1)
	if min != payments.MinimumCharge() {
		t.Fatalf("minimum discounted charge = %d, want %d", min, payments.MinimumCharge())
	}
}
