package registry

import (
	"testing"
	"time"
)

func TestCacheAffinityPrefersPreviousProviderWhenCostsClose(t *testing.T) {
	reg := New(testLogger())
	model := "cache-affinity-close"
	previous := makeSchedulerProvider(t, reg, "previous", model, 95)
	fast := makeSchedulerProvider(t, reg, "fast", model, 100)
	scope := "scope-hash"

	reg.RecordCacheAffinity("acct-a", model, scope, previous.ID)
	selected, _ := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "req-affinity",
		Model:              model,
		ConsumerKey:        "acct-a",
		RequestedMaxTokens: 128,
		CacheAffinityKey:   scope,
	})
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil")
	}
	if selected.ID != previous.ID {
		t.Fatalf("selected %q, want affinity provider %q over close faster provider %q", selected.ID, previous.ID, fast.ID)
	}
}

func TestCacheAffinityDifferentAccountsDoNotShare(t *testing.T) {
	reg := New(testLogger())
	model := "cache-affinity-account"
	previous := makeSchedulerProvider(t, reg, "previous", model, 20)
	fast := makeSchedulerProvider(t, reg, "fast", model, 200)
	scope := "scope-hash"

	reg.RecordCacheAffinity("acct-a", model, scope, previous.ID)
	selected, _ := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "req-affinity-other-account",
		Model:              model,
		ConsumerKey:        "acct-b",
		RequestedMaxTokens: 4096,
		CacheAffinityKey:   scope,
	})
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil")
	}
	if selected.ID != fast.ID {
		t.Fatalf("selected %q, want fast provider %q; affinity from another account must not apply", selected.ID, fast.ID)
	}
}

func TestCacheAffinityExpiredIgnored(t *testing.T) {
	reg := New(testLogger())
	reg.cacheAffinity = newCacheAffinityTracker(time.Millisecond)
	model := "cache-affinity-expired"
	previous := makeSchedulerProvider(t, reg, "previous", model, 20)
	fast := makeSchedulerProvider(t, reg, "fast", model, 200)
	scope := "scope-hash"

	reg.RecordCacheAffinity("acct-a", model, scope, previous.ID)
	time.Sleep(2 * time.Millisecond)
	selected, _ := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "req-affinity-expired",
		Model:              model,
		ConsumerKey:        "acct-a",
		RequestedMaxTokens: 4096,
		CacheAffinityKey:   scope,
	})
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil")
	}
	if selected.ID != fast.ID {
		t.Fatalf("selected %q, want fast provider %q; expired affinity to %q must be ignored", selected.ID, fast.ID, previous.ID)
	}
}

func TestCacheAffinityDoesNotBypassCapacity(t *testing.T) {
	reg := New(testLogger())
	model := "cache-affinity-capacity"
	full := makeSchedulerProvider(t, reg, "full", model, 200)
	open := makeSchedulerProvider(t, reg, "open", model, 80)
	full.mu.Lock()
	full.BackendCapacity.Slots[0].MaxConcurrency = 1
	full.BackendCapacity.Slots[0].NumRunning = 1
	full.mu.Unlock()
	scope := "scope-hash"
	reg.RecordCacheAffinity("acct-a", model, scope, full.ID)

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "req-affinity-full",
		Model:              model,
		ConsumerKey:        "acct-a",
		RequestedMaxTokens: 128,
		CacheAffinityKey:   scope,
	})
	if selected == nil {
		t.Fatalf("ReserveProviderEx returned nil; decision=%+v", decision)
	}
	if selected.ID != open.ID {
		t.Fatalf("selected %q, want open provider %q; affinity must not bypass capacity", selected.ID, open.ID)
	}
}
