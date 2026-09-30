package store

import "testing"

// TestReferralLifecycleBackends checks referrer registration, referral
// recording and the stats read on both store backends.
func TestReferralLifecycleBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			referrer := uniqueID("referrer-acct")
			code := uniqueID("REF")

			if err := s.CreateReferrer(referrer, code); err != nil {
				t.Fatalf("CreateReferrer: %v", err)
			}
			if err := s.CreateReferrer(uniqueID("other-acct"), code); err == nil {
				t.Fatal("a second account reused an existing referral code")
			}
			if err := s.CreateReferrer(referrer, uniqueID("REF")); err == nil {
				t.Fatal("one account registered two referral codes")
			}

			byCode, err := s.GetReferrerByCode(code)
			if err != nil || byCode.AccountID != referrer || byCode.Code != code || byCode.CreatedAt.IsZero() {
				t.Fatalf("GetReferrerByCode = %+v, %v", byCode, err)
			}
			byAccount, err := s.GetReferrerByAccount(referrer)
			if err != nil || byAccount.Code != code {
				t.Fatalf("GetReferrerByAccount = %+v, %v", byAccount, err)
			}
			if _, err := s.GetReferrerByCode(uniqueID("REF-missing")); err == nil {
				t.Fatal("unknown code returned a referrer")
			}
			if _, err := s.GetReferrerByAccount(uniqueID("acct-missing")); err == nil {
				t.Fatal("unknown account returned a referrer")
			}

			first, second := uniqueID("referred"), uniqueID("referred")
			if err := s.RecordReferral(uniqueID("REF-missing"), first); err == nil {
				t.Fatal("referral recorded against an unknown code")
			}
			for _, acct := range []string{first, second} {
				if err := s.RecordReferral(code, acct); err != nil {
					t.Fatalf("RecordReferral(%s): %v", acct, err)
				}
			}
			if err := s.RecordReferral(code, first); err == nil {
				t.Fatal("an account was referred twice")
			}

			if got, err := s.GetReferrerForAccount(first); err != nil || got != code {
				t.Fatalf("GetReferrerForAccount = %q, %v; want %q", got, err, code)
			}
			if got, err := s.GetReferrerForAccount(uniqueID("never-referred")); err != nil || got != "" {
				t.Fatalf("GetReferrerForAccount(unreferred) = %q, %v; want empty and nil", got, err)
			}

			// Only referral rewards credited to the referrer count.
			if err := s.Credit(referrer, 700, LedgerReferralReward, "ref-reward-1"); err != nil {
				t.Fatal(err)
			}
			if err := s.Credit(referrer, 300, LedgerReferralReward, "ref-reward-2"); err != nil {
				t.Fatal(err)
			}
			if err := s.Credit(referrer, 5_000, LedgerDeposit, "deposit-1"); err != nil {
				t.Fatal(err)
			}
			if err := s.Credit(first, 9_000, LedgerReferralReward, "not-the-referrer"); err != nil {
				t.Fatal(err)
			}

			stats, err := s.GetReferralStats(code)
			if err != nil {
				t.Fatalf("GetReferralStats: %v", err)
			}
			if stats.Code != code || stats.TotalReferred != 2 || stats.TotalRewardsMicroUSD != 1_000 {
				t.Fatalf("stats = %+v; want 2 referred and 1000 micro-USD rewards", stats)
			}
			if _, err := s.GetReferralStats(uniqueID("REF-missing")); err == nil {
				t.Fatal("stats returned for an unknown code")
			}
		})
	}
}
