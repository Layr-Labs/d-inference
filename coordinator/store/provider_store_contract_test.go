package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestProviderRecordStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testProviderRecordStoreContract(t, st)
		})
	}
}

func testProviderRecordStoreContract(t *testing.T, st Store) {
	t.Helper()

	ctx := context.Background()
	now := time.Date(2026, time.August, 22, 12, 0, 0, 0, time.UTC)
	accountA := uniqueID("provider-account-a")
	accountB := uniqueID("provider-account-b")
	serial := uniqueID("serial")
	chain, err := json.Marshal([][]byte{[]byte("leaf-der")})
	if err != nil {
		t.Fatalf("marshal MDA chain: %v", err)
	}
	oldID := uniqueID("provider-old")
	newID := uniqueID("provider-new")
	otherID := uniqueID("provider-other")
	for _, rec := range []ProviderRecord{
		{
			ID: oldID, SerialNumber: serial, AccountID: accountA,
			LastSeen: now.Add(-time.Minute), MDAVerified: true, MDACertChain: chain,
		},
		{
			ID: newID, SerialNumber: serial, AccountID: accountA,
			LastSeen: now,
		},
		{
			ID: otherID, SerialNumber: uniqueID("other-serial"), AccountID: accountB,
			LastSeen: now.Add(time.Minute),
		},
	} {
		if err := st.UpsertProvider(ctx, rec); err != nil {
			t.Fatalf("upsert provider %q: %v", rec.ID, err)
		}
	}

	latest, err := st.GetProviderBySerial(ctx, serial)
	if err != nil || latest == nil || latest.ID != newID || len(latest.MDACertChain) != 0 {
		t.Fatalf("latest serial provider = %+v err=%v", latest, err)
	}
	gotChain, err := st.GetMDAChainBySerial(ctx, serial)
	if err != nil || string(gotChain) != string(chain) {
		t.Fatalf("MDA chain = %q err=%v, want %q", gotChain, err, chain)
	}
	if missing, err := st.GetMDAChainBySerial(ctx, uniqueID("missing-serial")); err != nil || missing != nil {
		t.Fatalf("missing MDA chain = %q err=%v", missing, err)
	}
	if got, err := st.GetProviderRecord(ctx, oldID); err != nil || got == nil || got.ID != oldID {
		t.Fatalf("get provider record = %+v err=%v", got, err)
	}
	all, err := st.ListProviderRecords(ctx)
	if err != nil || len(all) != 3 {
		t.Fatalf("list provider records = %+v err=%v", all, err)
	}
	accountRecords, err := st.ListProvidersByAccount(ctx, accountA)
	if err != nil || len(accountRecords) != 2 ||
		accountRecords[0].ID != newID ||
		accountRecords[1].ID != oldID {
		t.Fatalf("account provider records = %+v err=%v", accountRecords, err)
	}
	if empty, err := st.ListProvidersByAccount(ctx, ""); err != nil || len(empty) != 0 {
		t.Fatalf("empty-account provider records = %+v err=%v", empty, err)
	}

	if err := st.UpsertReputation(ctx, oldID, ReputationRecord{TotalJobs: 5}); err != nil {
		t.Fatalf("upsert reputation: %v", err)
	}
	jobID := uniqueID("provider-history-job")
	if err := st.RecordProviderEarning(&ProviderEarning{
		AccountID: accountA, ProviderID: oldID, ProviderKey: uniqueID("provider-history-key"),
		JobID: jobID, Model: "model", AmountMicroUSD: 123, CreatedAt: now,
	}); err != nil {
		t.Fatalf("record provider history: %v", err)
	}
	if deleted, err := st.DeleteProvidersBySerial(ctx, accountB, serial); err != nil || deleted != 0 {
		t.Fatalf("wrong-owner delete = %d err=%v", deleted, err)
	}
	if deleted, err := st.DeleteProvidersBySerial(ctx, accountA, serial); err != nil || deleted != 2 {
		t.Fatalf("delete by serial = %d err=%v, want 2", deleted, err)
	}
	if records, err := st.ListProvidersByAccount(ctx, accountA); err != nil || len(records) != 0 {
		t.Fatalf("deleted account providers = %+v err=%v", records, err)
	}
	if records, err := st.ListProvidersByAccount(ctx, accountB); err != nil || len(records) != 1 {
		t.Fatalf("other account providers = %+v err=%v", records, err)
	}
	rep, err := st.GetReputation(ctx, oldID)
	if err == nil || rep != nil {
		t.Fatalf("deleted provider reputation = %+v err=%v, want not-found error", rep, err)
	}
	history, err := st.GetAccountEarnings(accountA, 10)
	if err != nil || len(history) != 1 || history[0].JobID != jobID {
		t.Fatalf("provider earning history after delete = %+v err=%v", history, err)
	}

	noSerialID := uniqueID("provider-without-serial")
	if err := st.UpsertProvider(ctx, ProviderRecord{ID: noSerialID, AccountID: accountA, LastSeen: now}); err != nil {
		t.Fatalf("upsert provider without serial: %v", err)
	}
	if deleted, err := st.DeleteProvidersBySerial(ctx, accountA, noSerialID); err != nil || deleted != 1 {
		t.Fatalf("delete by provider ID = %d err=%v, want 1", deleted, err)
	}
	deletedProvider, err := st.GetProviderRecord(ctx, noSerialID)
	if err == nil || deletedProvider != nil {
		t.Fatalf("provider after ID delete = %+v err=%v, want not-found error", deletedProvider, err)
	}
}
