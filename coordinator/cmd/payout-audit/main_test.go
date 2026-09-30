package main

import (
	"bytes"
	"context"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestRefundRequiresExactOperatorAssertions(t *testing.T) {
	id := "a96a14d8-360a-4dd9-8c41-1dde880bab73"
	for _, args := range [][]string{
		{"--apply-refund", id},
		{"--apply-refund", id, "--expected-amount-micro-usd", "1000000"},
		{"--apply-refund", id, "--expected-amount-micro-usd", "-1", "--verified-stripe-request", "req_verified"},
		{"--verified-stripe-request", "req_verified"},
		{"--limit", "100000"},
	} {
		if _, err := parseOptions(args); err == nil {
			t.Fatalf("unsafe options accepted: %v", args)
		}
	}
	if _, err := parseOptions([]string{"--apply-refund", id, "--expected-amount-micro-usd", "1000000", "--verified-stripe-request", "req_verified"}); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresAuditAndApprovedRefund(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("disposable DATABASE_URL required")
	}
	t.Setenv("EIGENINFERENCE_DATABASE_URL", dsn)
	ctx := context.Background()
	s, err := store.NewPostgres(ctx, store.Config{DatabaseURL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	id := uuid.NewString()
	account := "audit-" + id
	if err := s.CreditWithdrawable(account, 10_000_000, store.LedgerPayout, "test"); err != nil {
		t.Fatal(err)
	}
	w := &store.StripeWithdrawal{ID: id, AccountID: account, StripeAccountID: "acct_old", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "failed", FailureReason: "transfer_create_failed: stripe 400 [balance_insufficient]"}
	if err := s.CreateStripeWithdrawalWithDebit(w, store.LedgerStripePayout, "stripe_withdraw:"+id); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := run(ctx, []string{"--limit", "2"}, &output); err != nil {
		t.Fatal(err)
	}
	if s.GetBalance(account) != 5_000_000 {
		t.Fatal("read-only audit changed balance")
	}
	args := []string{"--apply-refund", id, "--expected-amount-micro-usd", "4000000", "--verified-stripe-request", "req_test"}
	if err := run(ctx, args, &output); err == nil {
		t.Fatal("mismatched approval accepted")
	}
	if s.GetBalance(account) != 5_000_000 {
		t.Fatal("wrong amount changed balance")
	}
	args[3] = "5000000"
	for range 2 {
		if err := run(ctx, args, &output); err != nil {
			t.Fatal(err)
		}
	}
	if s.GetBalance(account) != 10_000_000 {
		t.Fatal("approved retry duplicated or lost refund")
	}
	row, err := s.GetStripeWithdrawal(id)
	if err != nil || !row.Refunded {
		t.Fatalf("refund state: %+v %v", row, err)
	}
}
