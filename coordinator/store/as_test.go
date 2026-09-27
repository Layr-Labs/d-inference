package store

import (
	"context"
	"testing"
	"time"
)

// Mirrors of the optional capabilities the api package probes for with
// store.As (api/code_attest_throttle.go codeAttestPushBudgetStore and
// api/mdm_scheduler.go verificationDuePageStore). Neither is part of Store;
// both backends implement them.
type pushBudgetCapability interface {
	ListCodeAttestPushBudgets(ctx context.Context) ([]CodeAttestPushBudget, error)
	ReserveCodeAttestPushBudget(ctx context.Context, seKey, tokenHash string, now, nextPushAt time.Time) (bool, error)
	ClearCodeAttestPushFloor(ctx context.Context, seKey string, now time.Time, cooldown time.Duration) (time.Time, bool, error)
}

type duePageCapability interface {
	ListDueVerificationJobsPage(ctx context.Context, now time.Time, limit, offset int) ([]VerificationJob, error)
}

// opaqueStore is a decorator that does NOT implement Unwrapper: As must stop
// at it rather than guess.
type opaqueStore struct{ Store }

func TestAsFindsOptionalCapabilitiesThroughCachedStore(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			if _, ok := backend.(pushBudgetCapability); !ok {
				t.Fatalf("%s backend no longer implements the push-budget capability", name)
			}
			if _, ok := backend.(duePageCapability); !ok {
				t.Fatalf("%s backend no longer implements the due-page capability", name)
			}

			cached := NewCached(backend, CacheConfig{})

			// The bug shape: a direct assertion on the decorator fails ...
			if _, ok := any(cached).(pushBudgetCapability); ok {
				t.Fatal("direct assertion on CachedStore unexpectedly succeeded; this test no longer exercises the wrapped path")
			}
			if _, ok := any(cached).(duePageCapability); ok {
				t.Fatal("direct assertion on CachedStore unexpectedly succeeded; this test no longer exercises the wrapped path")
			}

			// ... and As is the supported probe, returning the backend itself.
			budgets, ok := As[pushBudgetCapability](cached)
			if !ok {
				t.Fatal("As did not find the push-budget capability through CachedStore")
			}
			if any(budgets) != any(backend) {
				t.Fatalf("As returned %T, want the wrapped backend %T", budgets, backend)
			}
			paged, ok := As[duePageCapability](cached)
			if !ok {
				t.Fatal("As did not find the due-page capability through CachedStore")
			}
			if any(paged) != any(backend) {
				t.Fatalf("As returned %T, want the wrapped backend %T", paged, backend)
			}

			// Through a narrow sub-interface value (the api fields are typed
			// codeAttestStore / store.ProviderStore, not Store) and through
			// nested decorators.
			var narrow ProviderStore = cached
			if _, ok := As[duePageCapability](narrow); !ok {
				t.Fatal("As failed on a narrow sub-interface value")
			}
			if _, ok := As[pushBudgetCapability](NewCached(cached, CacheConfig{})); !ok {
				t.Fatal("As failed through two decorator layers")
			}

			// The capability found through As reaches the same rows the
			// wrapped store holds.
			now := time.Now().UTC()
			seKey := uniqueID("se-as")
			if _, err := cached.UpsertVerificationJob(context.Background(), VerificationJob{
				SEPubKey: seKey, Serial: "serial", Kind: VerificationTaskSecurityInfo,
				State: VerificationStatePending, Priority: VerificationPriorityFirstOrExpired,
				NextAttemptAt: now.Add(-time.Minute), UpdatedAt: now,
			}); err != nil {
				t.Fatalf("UpsertVerificationJob: %v", err)
			}
			rows, err := paged.ListDueVerificationJobsPage(context.Background(), now, 100, 0)
			if err != nil {
				t.Fatalf("ListDueVerificationJobsPage: %v", err)
			}
			found := false
			for _, r := range rows {
				found = found || r.SEPubKey == seKey
			}
			if !found {
				t.Fatalf("capability reached via As does not see the wrapped store's rows: %+v", rows)
			}
		})
	}
}

func TestAsStopsAtNonUnwrappingDecoratorsAndNil(t *testing.T) {
	mem := NewMemory(Config{})
	if _, ok := As[pushBudgetCapability](mem); !ok {
		t.Fatal("As must succeed on the bare backend")
	}
	if _, ok := As[pushBudgetCapability](opaqueStore{mem}); ok {
		t.Fatal("As must not see through a decorator that does not implement Unwrapper")
	}
	if _, ok := As[pushBudgetCapability](NewCached(opaqueStore{mem}, CacheConfig{})); ok {
		t.Fatal("As must stop at the first non-unwrapping layer")
	}
	if _, ok := As[pushBudgetCapability](nil); ok {
		t.Fatal("As(nil) must be false")
	}
	var nilStore Store
	if _, ok := As[pushBudgetCapability](nilStore); ok {
		t.Fatal("As(nil Store) must be false")
	}
	// Probing for something a backend genuinely lacks is false, not a panic.
	type absent interface{ DefinitelyNotImplemented() }
	if _, ok := As[absent](NewCached(mem, CacheConfig{})); ok {
		t.Fatal("As found a capability nothing implements")
	}
}
