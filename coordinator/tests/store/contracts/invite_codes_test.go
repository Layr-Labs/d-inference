package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInviteCodeRedemptionRulesBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			code := uniqueID("INV")
			if err := s.CreateInviteCode(&store.InviteCode{Code: code, AmountMicroUSD: 5_000_000, MaxUses: 2, Active: true}); err != nil {
				t.Fatalf("CreateInviteCode: %v", err)
			}
			if err := s.CreateInviteCode(&store.InviteCode{Code: code, AmountMicroUSD: 1, MaxUses: 1, Active: true}); err == nil {
				t.Fatal("duplicate invite code accepted")
			}

			got, err := s.GetInviteCode(code)
			if err != nil || got.AmountMicroUSD != 5_000_000 || got.MaxUses != 2 || got.UsedCount != 0 || !got.Active {
				t.Fatalf("GetInviteCode = %+v, %v", got, err)
			}
			if _, err := s.GetInviteCode(uniqueID("INV-missing")); err == nil {
				t.Fatal("unknown invite code returned")
			}

			first, second, third := uniqueID("acct"), uniqueID("acct"), uniqueID("acct")
			if err := s.RedeemInviteCode(code, first); err != nil {
				t.Fatalf("first redemption: %v", err)
			}
			if err := s.RedeemInviteCode(code, first); err == nil {
				t.Fatal("one account redeemed the same code twice")
			}
			if err := s.RedeemInviteCode(code, second); err != nil {
				t.Fatalf("second redemption: %v", err)
			}
			if err := s.RedeemInviteCode(code, third); err == nil {
				t.Fatal("redemption past max uses accepted")
			}
			if got, _ := s.GetInviteCode(code); got == nil || got.UsedCount != 2 {
				t.Fatalf("used count after two redemptions = %+v", got)
			}

			expiredAt := time.Now().Add(-time.Hour)
			expired := uniqueID("INV-expired")
			if err := s.CreateInviteCode(&store.InviteCode{Code: expired, AmountMicroUSD: 1, MaxUses: 0, Active: true, ExpiresAt: &expiredAt}); err != nil {
				t.Fatal(err)
			}
			if err := s.RedeemInviteCode(expired, first); err == nil {
				t.Fatal("expired invite code redeemed")
			}

			unlimited := uniqueID("INV-unlimited")
			if err := s.CreateInviteCode(&store.InviteCode{Code: unlimited, AmountMicroUSD: 1, MaxUses: 0, Active: true}); err != nil {
				t.Fatal(err)
			}
			for _, acct := range []string{first, second, third} {
				if err := s.RedeemInviteCode(unlimited, acct); err != nil {
					t.Fatalf("unlimited code redemption by %s: %v", acct, err)
				}
			}
			if err := s.DeactivateInviteCode(unlimited); err != nil {
				t.Fatalf("DeactivateInviteCode: %v", err)
			}
			if err := s.RedeemInviteCode(unlimited, uniqueID("acct")); err == nil {
				t.Fatal("inactive invite code redeemed")
			}
			if got, _ := s.GetInviteCode(unlimited); got == nil || got.Active || got.UsedCount != 3 {
				t.Fatalf("deactivated code = %+v", got)
			}

			if err := s.DeactivateInviteCode(uniqueID("INV-missing")); err == nil {
				t.Fatal("unknown invite code deactivated")
			}
			if err := s.RedeemInviteCode(uniqueID("INV-missing"), first); err == nil {
				t.Fatal("unknown invite code redeemed")
			}

			listed := map[string]store.InviteCode{}
			for _, ic := range s.ListInviteCodes() {
				listed[ic.Code] = ic
			}
			for _, want := range []string{code, expired, unlimited} {
				if _, ok := listed[want]; !ok {
					t.Fatalf("ListInviteCodes is missing %s", want)
				}
			}
		})
	}
}
