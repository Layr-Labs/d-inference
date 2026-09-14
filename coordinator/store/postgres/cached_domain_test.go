package postgres

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	storecache "github.com/eigeninference/d-inference/coordinator/store/cache"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/testfixture"
)

// A read that fetched its value from the inner store BEFORE a write but tries
// to publish it AFTER that write's invalidation must be rejected -- otherwise
// the cache would serve pre-write data for a full TTL. Without the generation
// guard in domainCache.store this test fails.
func TestCachedStoreRejectsLoadThatRacedWithWrite(t *testing.T) {
	cached, counting, _ := newCachedMemoryStore(t)
	testfixture.SeedUser(t, cached, "acct-1")

	loaded := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	counting.afterLoad = func() {
		once.Do(func() {
			close(loaded)
			<-release
		})
	}

	type result struct {
		u   *contracts.User
		err error
	}
	done := make(chan result, 1)
	go func() {
		u, err := cached.GetUserByAccountID("acct-1")
		done <- result{u, err}
	}()

	<-loaded // reader holds the pre-write value, not yet published
	if err := cached.SetUserRole("acct-1", contracts.RoleService); err != nil {
		t.Fatal(err)
	}
	close(release)
	r := <-done
	if r.err != nil || r.u.Role != "" {
		t.Fatalf("racing reader should return what it loaded (pre-write): %+v %v", r.u, r.err)
	}

	// The pre-write value must not have been cached: this read goes to the
	// inner store and sees the new role.
	before := counting.count("GetUserByAccountID")
	u, err := cached.GetUserByAccountID("acct-1")
	if err != nil {
		t.Fatal(err)
	}
	if u.Role != contracts.RoleService {
		t.Fatalf("stale pre-write value served from cache: role %q", u.Role)
	}
	if got := counting.count("GetUserByAccountID"); got != before+1 {
		t.Fatalf("expected a fresh inner read, inner calls %d -> %d", before, got)
	}
}

// Run with -race: readers, writers and invalidations interleave on shared
// keys; the cache must stay bounded and end up coherent with the inner store.
func TestCachedStoreConcurrentReadersAndWriters(t *testing.T) {
	cached, _, clock := newCachedMemoryStore(t)
	const users, models = 6, 3
	for i := 0; i < users; i++ {
		testfixture.SeedUser(t, cached, fmt.Sprintf("acct-%d", i))
	}
	for i := 0; i < models; i++ {
		seedActiveModel(t, cached, fmt.Sprintf("org/m%d", i), "v1")
	}

	var wg sync.WaitGroup
	errs := make(chan error, 64)
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 300; i++ {
				id := fmt.Sprintf("acct-%d", (g+i)%users)
				if u, err := cached.GetUserByAccountID(id); err != nil || u.AccountID != id {
					errs <- fmt.Errorf("user %s: %+v %v", id, u, err)
					return
				}
				if _, err := cached.GetUserByPrivyID("did:privy:" + id); err != nil {
					errs <- err
					return
				}
				mid := fmt.Sprintf("org/m%d", (g+i)%models)
				rec, err := cached.GetModelRegistryRecord(mid)
				if err != nil || rec.ID != mid || rec.ActiveVersion == nil {
					errs <- fmt.Errorf("model %s: %+v %v", mid, rec, err)
					return
				}
				rec.RuntimeParameters["scribble"] = i // copies: must not race with other readers
				if _, err := cached.GetModelManifest(mid); err != nil {
					errs <- err
					return
				}
				if _, err := cached.GetUserByAccountID("ghost"); !errors.Is(err, contracts.ErrNotFound) {
					errs <- fmt.Errorf("ghost: %v", err)
					return
				}
				if i%50 == 0 {
					clock.Advance(time.Second)
				}
			}
		}(g)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		fee := int64(3)
		for i := 0; i < 60; i++ {
			id := fmt.Sprintf("acct-%d", i%users)
			role := ""
			if i%2 == 0 {
				role = contracts.RoleService
			}
			if err := cached.SetUserRole(id, role); err != nil {
				errs <- err
				return
			}
			if err := cached.SetUserPlatformFeePercent(id, &fee); err != nil {
				errs <- err
				return
			}
			mid := fmt.Sprintf("org/m%d", i%models)
			entry, _, _ := registryFixture(mid, "v1")
			entry.DisplayName = fmt.Sprintf("rev-%d", i)
			if err := cached.UpsertModelRegistryEntry(entry); err != nil {
				errs <- err
				return
			}
			if err := cached.SetModelStatus(mid, "active"); err != nil {
				errs <- err
				return
			}
		}
	}()
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}

	// Coherence after quiescence: every cached read equals the inner store.
	inner := cached.Store.(*countingStore).Store
	for i := 0; i < users; i++ {
		id := fmt.Sprintf("acct-%d", i)
		want, _ := inner.GetUserByAccountID(id)
		got, _ := cached.GetUserByAccountID(id)
		if got.Role != want.Role || (got.PlatformFeePercent == nil) != (want.PlatformFeePercent == nil) {
			t.Fatalf("user %s incoherent: cached %+v inner %+v", id, got, want)
		}
	}
	for i := 0; i < models; i++ {
		mid := fmt.Sprintf("org/m%d", i)
		want, _ := inner.GetModelRegistryRecord(mid)
		got, _ := cached.GetModelRegistryRecord(mid)
		if got.DisplayName != want.DisplayName {
			t.Fatalf("model %s incoherent: cached %q inner %q", mid, got.DisplayName, want.DisplayName)
		}
	}
	st := cached.Stats()
	if st.Users.Entries > storecache.DefaultCacheConfig().MaxUsers || st.Models.Entries > storecache.DefaultCacheConfig().MaxModels {
		t.Fatalf("cache exceeded bounds: %+v", st)
	}
	if st.Users.Invalidations < 120 || st.Models.Invalidations < 120 {
		t.Fatalf("expected every write to invalidate: %+v", st)
	}
}
