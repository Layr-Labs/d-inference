package store

import (
	"context"
	"sync"
	"testing"
)

func TestInviteRedemptionCreditsOneWinningAccount(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			const code = "INV-SINGLE"
			if err := s.CreateInviteCode(&InviteCode{Code: code, AmountMicroUSD: 2_000_000, MaxUses: 1, Active: true}); err != nil {
				t.Fatal(err)
			}
			accounts := []string{"invite-a", "invite-b"}
			for _, id := range accounts {
				if err := s.CreateUser(&User{AccountID: id, PrivyUserID: "did:" + id}); err != nil {
					t.Fatal(err)
				}
			}
			start := make(chan struct{})
			results := make(chan error, 2)
			var wg sync.WaitGroup
			for _, id := range accounts {
				wg.Add(1)
				go func(id string) { defer wg.Done(); <-start; results <- s.RedeemInviteCode(code, id) }(id)
			}
			close(start)
			wg.Wait()
			close(results)
			successes := 0
			for err := range results {
				if err == nil {
					successes++
				}
			}
			if successes != 1 {
				t.Fatalf("successful redemptions=%d", successes)
			}
			total := int64(0)
			for _, id := range accounts {
				b, w := s.GetBalanceWithWithdrawable(id)
				total += b
				if w != 0 {
					t.Errorf("invite funds withdrawable for %s: %d", id, w)
				}
				if s.HasRedeemedInviteCode(code, id) != (b == 2_000_000) {
					t.Errorf("claim and balance disagree for %s: %d", id, b)
				}
				if err := s.RedeemInviteCode(code, id); err == nil {
					t.Error("exhausted invite redeemed again")
				}
			}
			if total != 2_000_000 {
				t.Errorf("total credit=%d", total)
			}
			ic, err := s.GetInviteCode(code)
			if err != nil || ic.UsedCount != 1 {
				t.Errorf("invite=%+v err=%v", ic, err)
			}
		})
	}
}

func TestPostgresInviteCreditFailureRollsBackClaim(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	const code, account = "INV-ROLLBACK", "invite-rollback"
	if err := s.CreateUser(&User{AccountID: account, PrivyUserID: "did:" + account}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateInviteCode(&InviteCode{Code: code, AmountMicroUSD: 3_000_000, MaxUses: 1, Active: true}); err != nil {
		t.Fatal(err)
	}
	_, err := s.pool.Exec(ctx, `CREATE FUNCTION reject_invite_credit_test() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.entry_type = 'invite_credit' THEN RAISE EXCEPTION 'forced invite credit failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER reject_invite_credit_test BEFORE INSERT ON ledger_entries FOR EACH ROW EXECUTE FUNCTION reject_invite_credit_test()`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(context.Background(), `DROP TRIGGER IF EXISTS reject_invite_credit_test ON ledger_entries; DROP FUNCTION IF EXISTS reject_invite_credit_test()`)
	})
	if err := s.RedeemInviteCode(code, account); err == nil {
		t.Fatal("forced credit failure accepted")
	}
	ic, err := s.GetInviteCode(code)
	if err != nil || ic.UsedCount != 0 || s.HasRedeemedInviteCode(code, account) || s.GetBalance(account) != 0 {
		t.Fatalf("partial redemption after failed credit: invite=%+v err=%v claimed=%v balance=%d", ic, err, s.HasRedeemedInviteCode(code, account), s.GetBalance(account))
	}
	if _, err := s.pool.Exec(ctx, `DROP TRIGGER reject_invite_credit_test ON ledger_entries`); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInviteCode(code, account); err != nil {
		t.Fatalf("retry after rollback: %v", err)
	}
	if got := s.GetBalance(account); got != 3_000_000 {
		t.Fatalf("retry balance=%d", got)
	}
	var rows int
	if err := s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM ledger_entries WHERE account_id=$1 AND entry_type='invite_credit'`, account).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("credit ledger rows=%d err=%v", rows, err)
	}
}
