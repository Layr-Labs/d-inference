package registry

import (
	"sync"
	"testing"
	"time"
)

func TestAppAttestDuplicateConnectionsKeepNewestQualified(t *testing.T) {
	r, old, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(old, lease) {
		t.Fatal("grant old")
	}
	newest := makeSchedulerProvider(t, r, "new-session", appAttestTestModel, 90)
	newest.RequireVerifiedMachineIdentity()
	newest.mu.Lock()
	newest.AccountID = lease.AccountID
	newest.registeredAt = old.registeredAt.Add(time.Second)
	newest.mu.Unlock()
	if !r.BindVerifiedMachineIdentity(newest, lease.AccountID, lease.MachineID) {
		t.Fatal("bind new")
	}
	newLease := lease
	newLease.ConnectionID = newest.ID
	if !r.GrantAppAttestServingAuthorization(newest, newLease) {
		t.Fatal("grant new")
	}
	other := makeSchedulerProvider(t, r, "other-account", appAttestTestModel, 90)
	other.mu.Lock()
	other.AccountID = "other"
	other.mu.Unlock()
	if !r.BindVerifiedMachineIdentity(other, "other", lease.MachineID) {
		t.Fatal("bind other")
	}
	var wg sync.WaitGroup
	for _, p := range []*Provider{old, newest} {
		wg.Add(1)
		go func(p *Provider) { defer wg.Done(); r.DisconnectDuplicatesByMachine(p) }(p)
	}
	wg.Wait()
	if r.GetProvider(old.ID) != nil {
		t.Fatal("older duplicate survived")
	}
	if r.GetProvider(newest.ID) != newest {
		t.Fatal("simultaneous arbitration evicted winner")
	}
	if r.GetProvider(other.ID) != other {
		t.Fatal("another account was evicted")
	}
}

func TestAppAttestProvisionalConnectionCannotEvict(t *testing.T) {
	r, qualified, lease := appAttestTestProvider(t)
	if !r.GrantAppAttestServingAuthorization(qualified, lease) {
		t.Fatal("grant")
	}
	pending := makeSchedulerProvider(t, r, "pending", appAttestTestModel, 90)
	pending.mu.Lock()
	pending.AccountID = lease.AccountID
	pending.mu.Unlock()
	if !r.BindVerifiedMachineIdentity(pending, lease.AccountID, lease.MachineID) {
		t.Fatal("bind")
	}
	r.DisconnectDuplicatesByMachine(pending)
	if r.GetProvider(qualified.ID) != qualified {
		t.Fatal("pending proof evicted qualified provider")
	}
	r.DisconnectDuplicatesByMachine(qualified)
	if r.GetProvider(pending.ID) != pending {
		t.Fatal("older renewal evicted newer connection before qualification")
	}
}
