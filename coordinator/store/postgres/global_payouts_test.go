package postgres

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func payoutFixture(t *testing.T, s store.Store, g store.GlobalPayoutStore, account, id string) store.GlobalPayout {
	t.Helper()
	if err := s.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(account, 10_000_000, store.LedgerPayout, "earn-"+account); err != nil {
		t.Fatal(err)
	}
	r := store.GlobalRecipient{ID: "generation-" + id, AccountID: account, Country: "IN", RecipientID: "acct_" + id, PayoutMethodID: "pm_" + id, Ready: true}
	if _, err := g.PrepareGlobalRecipient(r); err != nil {
		t.Fatal(err)
	}
	p := store.GlobalPayout{ID: id, AccountID: account, RecipientGeneration: r.ID, RecipientID: r.RecipientID, PayoutMethodID: r.PayoutMethodID, Country: "IN", AmountMicroUSD: 8_000_000, DestinationAmount: 64000, Currency: "inr", Request: []byte(`{"amount":{"value":800,"currency":"usd"}}`), Status: "quoted", CreatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Minute)}
	if err := g.CreateGlobalPayoutQuote(p); err != nil {
		t.Fatal(err)
	}
	return p
}
