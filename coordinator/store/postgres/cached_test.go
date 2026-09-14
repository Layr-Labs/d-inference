package postgres

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	storecache "github.com/eigeninference/d-inference/coordinator/store/cache"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
	"github.com/eigeninference/d-inference/coordinator/store/internal/testfixture"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// countingStore forwards every call to a real Store and counts the inner
// reads of the lookups CachedStore caches. It is not a mock of behavior: the
// wrapped store answers every call. failWith and afterLoad exist so tests can
// exercise the transient-error and read/write-race paths deterministically.
type countingStore struct {
	contracts.Store
	mu        sync.Mutex
	calls     map[string]int
	failWith  error  // when set, cached lookups return it instead of forwarding
	afterLoad func() // runs after the inner read, before returning (race test)
}

func newCountingStore(inner contracts.Store) *countingStore {
	return &countingStore{Store: inner, calls: map[string]int{}}
}

func (c *countingStore) note(name string) {
	c.mu.Lock()
	c.calls[name]++
	c.mu.Unlock()
}

func (c *countingStore) count(name string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls[name]
}

func (c *countingStore) GetUserByAccountID(accountID string) (*contracts.User, error) {
	c.note("GetUserByAccountID")
	if c.failWith != nil {
		return nil, c.failWith
	}
	u, err := c.Store.GetUserByAccountID(accountID)
	if c.afterLoad != nil {
		c.afterLoad()
	}
	return u, err
}

func (c *countingStore) GetUserByPrivyID(privyUserID string) (*contracts.User, error) {
	c.note("GetUserByPrivyID")
	if c.failWith != nil {
		return nil, c.failWith
	}
	return c.Store.GetUserByPrivyID(privyUserID)
}

func (c *countingStore) GetModelRegistryRecord(modelID string) (*contracts.ModelRegistryRecord, error) {
	c.note("GetModelRegistryRecord")
	if c.failWith != nil {
		return nil, c.failWith
	}
	rec, err := c.Store.GetModelRegistryRecord(modelID)
	if c.afterLoad != nil {
		c.afterLoad()
	}
	return rec, err
}

func (c *countingStore) GetModelManifest(modelID string) (*contracts.ModelManifest, error) {
	c.note("GetModelManifest")
	return c.Store.GetModelManifest(modelID)
}

// newCachedMemoryStore composes CachedStore -> countingStore -> MemoryStore
// with a fake clock and the production TTLs.
func newCachedMemoryStore(t *testing.T) (*storecache.Store, *countingStore, *testfixture.Clock) {
	t.Helper()
	clock := testfixture.NewClock()
	counting := newCountingStore(memory.New(contracts.Config{}))
	cfg := storecache.DefaultCacheConfig()
	cfg.Now = clock.Now
	return storecache.New(counting, cfg), counting, clock
}

const cachedTestHash = "0000000000000000000000000000000000000000000000000000000000000000"

func registryFixture(modelID, version string) (*contracts.ModelRegistryEntry, *contracts.ModelVersion, []contracts.ModelVersionFile) {
	entry := &contracts.ModelRegistryEntry{
		ID: modelID, DisplayName: "Model " + modelID, Status: "active", MinRAMGB: 16,
		MaxContextLength: 32768, MaxOutputLength: 8192,
		Capabilities:                 []string{"chat"},
		RequiredProviderCapabilities: []string{},
		RuntimeParameters:            map[string]any{"reasoning_parser": "qwen3", "nested": map[string]any{"k": []any{"a", "b"}}},
		Metadata:                     map[string]any{"hugging_face_id": "org/" + modelID},
	}
	v := &contracts.ModelVersion{ModelID: modelID, Version: version, R2Prefix: modelID + "/" + version,
		AggregateSHA256: cachedTestHash, TotalSizeBytes: 3, FileCount: 1, Status: "ready"}
	files := []contracts.ModelVersionFile{{Path: "config.json", SizeBytes: 3, SHA256: cachedTestHash, Role: "config"}}
	return entry, v, files
}

// seedActiveModel registers and promotes one ready version so the model has
// an active registry record.
func seedActiveModel(t *testing.T, st contracts.Store, modelID, version string) {
	t.Helper()
	entry, v, files := registryFixture(modelID, version)
	if err := st.SetModelVersion(entry, v, files); err != nil {
		t.Fatalf("SetModelVersion(%s %s): %v", modelID, version, err)
	}
	if err := st.PromoteModelVersion(modelID, version); err != nil {
		t.Fatalf("PromoteModelVersion(%s %s): %v", modelID, version, err)
	}
}

func TestCachedStoreUserHitAfterMiss(t *testing.T) {
	cached, counting, _ := newCachedMemoryStore(t)
	testfixture.SeedUser(t, cached, "acct-1")

	for i := 0; i < 3; i++ {
		u, err := cached.GetUserByAccountID("acct-1")
		if err != nil || u.AccountID != "acct-1" || u.PrivyUserID != "did:privy:acct-1" {
			t.Fatalf("get %d: user=%+v err=%v", i, u, err)
		}
		u, err = cached.GetUserByPrivyID("did:privy:acct-1")
		if err != nil || u.AccountID != "acct-1" {
			t.Fatalf("privy get %d: user=%+v err=%v", i, u, err)
		}
	}
	if n := counting.count("GetUserByAccountID"); n != 1 {
		t.Fatalf("inner GetUserByAccountID calls = %d, want 1", n)
	}
	if n := counting.count("GetUserByPrivyID"); n != 1 {
		t.Fatalf("inner GetUserByPrivyID calls = %d, want 1", n)
	}
	st := cached.Stats()
	if st.Users.Hits != 4 || st.Users.Misses != 2 || st.Users.Entries != 2 {
		t.Fatalf("user stats = %+v, want 4 hits / 2 misses / 2 entries", st.Users)
	}
}

func TestCachedStoreUserTTLExpiry(t *testing.T) {
	cached, counting, clock := newCachedMemoryStore(t)
	testfixture.SeedUser(t, cached, "acct-1")

	cached.GetUserByAccountID("acct-1")
	clock.Advance(storecache.DefaultCacheConfig().UserTTL - time.Second)
	cached.GetUserByAccountID("acct-1")
	if n := counting.count("GetUserByAccountID"); n != 1 {
		t.Fatalf("calls before expiry = %d, want 1", n)
	}
	clock.Advance(2 * time.Second)
	cached.GetUserByAccountID("acct-1")
	if n := counting.count("GetUserByAccountID"); n != 2 {
		t.Fatalf("calls after expiry = %d, want 2", n)
	}
}

func TestCachedStoreNegativeUserCached(t *testing.T) {
	cached, counting, clock := newCachedMemoryStore(t)

	want := "user with account ID \"ghost\" not found"
	for i := 0; i < 3; i++ {
		u, err := cached.GetUserByAccountID("ghost")
		if u != nil || !errors.Is(err, contracts.ErrNotFound) {
			t.Fatalf("get %d: user=%v err=%v, want ErrNotFound", i, u, err)
		}
		if err.Error() != want {
			t.Fatalf("get %d: message %q, want %q (must match inner store verbatim)", i, err.Error(), want)
		}
	}
	if n := counting.count("GetUserByAccountID"); n != 1 {
		t.Fatalf("inner calls for a cached miss = %d, want 1", n)
	}
	if st := cached.Stats(); st.Users.NegativeHits != 2 {
		t.Fatalf("negative hits = %d, want 2", st.Users.NegativeHits)
	}

	clock.Advance(storecache.DefaultCacheConfig().NegativeTTL + time.Millisecond)
	cached.GetUserByAccountID("ghost")
	if n := counting.count("GetUserByAccountID"); n != 2 {
		t.Fatalf("inner calls after negative TTL = %d, want 2", n)
	}
}

func TestCachedStoreUserMutatorsInvalidate(t *testing.T) {
	fee := int64(0)
	cases := []struct {
		name   string
		mutate func(*storecache.Store) error
		check  func(*contracts.User) error
	}{
		{"CreateUser", func(c *storecache.Store) error {
			return c.CreateUser(&contracts.User{AccountID: "acct-other", PrivyUserID: "did:privy:other"})
		}, func(*contracts.User) error { return nil }},
		{"SetUserRole", func(c *storecache.Store) error {
			return c.SetUserRole("acct-1", contracts.RoleService)
		}, func(u *contracts.User) error {
			if u.Role != contracts.RoleService {
				return fmt.Errorf("role = %q, want %q", u.Role, contracts.RoleService)
			}
			return nil
		}},
		{"SetUserPlatformFeePercent", func(c *storecache.Store) error {
			return c.SetUserPlatformFeePercent("acct-1", &fee)
		}, func(u *contracts.User) error {
			if u.PlatformFeePercent == nil || *u.PlatformFeePercent != 0 {
				return fmt.Errorf("fee = %v, want 0", u.PlatformFeePercent)
			}
			return nil
		}},
		{"SetUserStripeAccount", func(c *storecache.Store) error {
			return c.SetUserStripeAccount("acct-1", "acct_stripe", "pending", "US", "card", "4242", true)
		}, func(u *contracts.User) error {
			if u.StripeAccountID != "acct_stripe" || u.StripeAccountStatus != "pending" {
				return fmt.Errorf("stripe = %q/%q, want acct_stripe/pending", u.StripeAccountID, u.StripeAccountStatus)
			}
			return nil
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cached, counting, _ := newCachedMemoryStore(t)
			testfixture.SeedUser(t, cached, "acct-1")
			cached.GetUserByAccountID("acct-1")
			cached.GetUserByPrivyID("did:privy:acct-1")
			before := counting.count("GetUserByAccountID") + counting.count("GetUserByPrivyID")

			if err := tc.mutate(cached); err != nil {
				t.Fatalf("mutate: %v", err)
			}
			u, err := cached.GetUserByAccountID("acct-1")
			if err != nil {
				t.Fatalf("get after mutate: %v", err)
			}
			if err := tc.check(u); err != nil {
				t.Fatalf("stale read after %s: %v", tc.name, err)
			}
			if _, err := cached.GetUserByPrivyID("did:privy:acct-1"); err != nil {
				t.Fatalf("privy get after mutate: %v", err)
			}
			after := counting.count("GetUserByAccountID") + counting.count("GetUserByPrivyID")
			if after != before+2 {
				t.Fatalf("inner reads after %s = %d, want %d (both user keys reloaded)", tc.name, after, before+2)
			}
		})
	}
}

// GetOrCreateUser's race branch re-reads by Privy ID after a failed
// CreateUser; both the miss recorded before creation and the failed create
// must leave the cache pointing at the real row.
func TestCachedStoreCreateUserClearsNegativeEntryEvenOnFailure(t *testing.T) {
	cached, counting, _ := newCachedMemoryStore(t)

	if _, err := cached.GetUserByPrivyID("did:privy:new"); !errors.Is(err, contracts.ErrNotFound) {
		t.Fatalf("expected miss, got %v", err)
	}
	testfixture.SeedUser(t, cached, "new") // CreateUser through the decorator
	if u, err := cached.GetUserByPrivyID("did:privy:new"); err != nil || u.AccountID != "new" {
		t.Fatalf("after create: user=%+v err=%v", u, err)
	}

	// Warm, then a duplicate CreateUser fails -- it must still invalidate.
	cached.GetUserByPrivyID("did:privy:new")
	n := counting.count("GetUserByPrivyID")
	if err := cached.CreateUser(&contracts.User{AccountID: "new", PrivyUserID: "did:privy:new"}); err == nil {
		t.Fatal("duplicate CreateUser should fail")
	}
	cached.GetUserByPrivyID("did:privy:new")
	if got := counting.count("GetUserByPrivyID"); got != n+1 {
		t.Fatalf("failed CreateUser did not invalidate: inner calls %d, want %d", got, n+1)
	}
}

func TestCachedStoreReturnsUserCopies(t *testing.T) {
	cached, _, _ := newCachedMemoryStore(t)
	testfixture.SeedUser(t, cached, "acct-1")
	fee := int64(7)
	if err := cached.SetUserPlatformFeePercent("acct-1", &fee); err != nil {
		t.Fatal(err)
	}

	u1, _ := cached.GetUserByAccountID("acct-1")
	u1.Role = "tampered"
	*u1.PlatformFeePercent = 99
	u1.Email = "tampered@example.test"

	u2, _ := cached.GetUserByAccountID("acct-1")
	if u2.Role != "" || *u2.PlatformFeePercent != 7 || u2.Email != "acct-1@example.test" {
		t.Fatalf("caller mutation leaked into cache: %+v", u2)
	}
	if u1 == u2 {
		t.Fatal("cache handed out the same pointer twice")
	}
}

func TestCachedStoreModelRecordAndManifestShareOneLoad(t *testing.T) {
	cached, counting, _ := newCachedMemoryStore(t)
	seedActiveModel(t, cached, "org/m1", "v1")

	for i := 0; i < 3; i++ {
		rec, err := cached.GetModelRegistryRecord("org/m1")
		if err != nil || rec.ActiveVersion == nil || rec.ActiveVersion.Version != "v1" || len(rec.Files) != 1 {
			t.Fatalf("record %d: %+v err=%v", i, rec, err)
		}
		m, err := cached.GetModelManifest("org/m1")
		if err != nil || m == nil || m.Version != "v1" || m.ModelID != "org/m1" || len(m.Files) != 1 || m.Files[0].Path != "config.json" {
			t.Fatalf("manifest %d: %+v err=%v", i, m, err)
		}
	}
	if n := counting.count("GetModelRegistryRecord"); n != 1 {
		t.Fatalf("inner GetModelRegistryRecord calls = %d, want 1", n)
	}
	if n := counting.count("GetModelManifest"); n != 0 {
		t.Fatalf("inner GetModelManifest calls = %d, want 0 (derived from the cached record)", n)
	}
	if st := cached.Stats(); st.Models.Hits != 5 || st.Models.Misses != 1 || st.Models.Entries != 1 {
		t.Fatalf("model stats = %+v", st.Models)
	}
}

func TestCachedStoreModelTTLExpiry(t *testing.T) {
	cached, counting, clock := newCachedMemoryStore(t)
	seedActiveModel(t, cached, "org/m1", "v1")

	cached.GetModelRegistryRecord("org/m1")
	clock.Advance(storecache.DefaultCacheConfig().ModelTTL - time.Second)
	cached.GetModelRegistryRecord("org/m1")
	if n := counting.count("GetModelRegistryRecord"); n != 1 {
		t.Fatalf("calls before expiry = %d, want 1", n)
	}
	clock.Advance(2 * time.Second)
	cached.GetModelRegistryRecord("org/m1")
	if n := counting.count("GetModelRegistryRecord"); n != 2 {
		t.Fatalf("calls after expiry = %d, want 2", n)
	}
}

// Alias names reach GetModelRegistryRecord on every request and always miss;
// that miss must be remembered for NegativeTTL, and both the sentinel and the
// exact message the API string-matches on must survive the cache.
func TestCachedStoreNegativeModelCached(t *testing.T) {
	cached, counting, clock := newCachedMemoryStore(t)

	want := `model "qwen3-alias" not found`
	for i := 0; i < 4; i++ {
		if _, err := cached.GetModelRegistryRecord("qwen3-alias"); !errors.Is(err, contracts.ErrNotFound) || err.Error() != want {
			t.Fatalf("record %d: err=%v want ErrNotFound %q", i, err, want)
		}
		if _, err := cached.GetModelManifest("qwen3-alias"); !errors.Is(err, contracts.ErrNotFound) || err.Error() != want {
			t.Fatalf("manifest %d: err=%v want ErrNotFound %q", i, err, want)
		}
	}
	if n := counting.count("GetModelRegistryRecord"); n != 1 {
		t.Fatalf("inner calls for a cached miss = %d, want 1", n)
	}
	clock.Advance(storecache.DefaultCacheConfig().NegativeTTL + time.Millisecond)
	cached.GetModelRegistryRecord("qwen3-alias")
	if n := counting.count("GetModelRegistryRecord"); n != 2 {
		t.Fatalf("inner calls after negative TTL = %d, want 2", n)
	}
}

func TestCachedStoreModelMutatorsInvalidate(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*storecache.Store) error
		check  func(*contracts.ModelRegistryRecord, error) error
	}{
		{"UpsertModelRegistryEntry", func(c *storecache.Store) error {
			entry, _, _ := registryFixture("org/m1", "v1")
			entry.DisplayName = "Renamed"
			entry.RuntimeParameters["reasoning_parser"] = "gemma"
			return c.UpsertModelRegistryEntry(entry)
		}, func(rec *contracts.ModelRegistryRecord, err error) error {
			if err != nil || rec.DisplayName != "Renamed" || rec.RuntimeParameters["reasoning_parser"] != "gemma" {
				return fmt.Errorf("rec=%+v err=%v", rec, err)
			}
			return nil
		}},
		{"SetModelVersion", func(c *storecache.Store) error {
			entry, v, files := registryFixture("org/m1", "v2")
			entry.MaxOutputLength = 16384
			return c.SetModelVersion(entry, v, files)
		}, func(rec *contracts.ModelRegistryRecord, err error) error {
			// v2 is uploaded but not promoted: entry fields changed, active stays v1.
			if err != nil || rec.MaxOutputLength != 16384 || rec.ActiveVersion.Version != "v1" {
				return fmt.Errorf("rec=%+v err=%v", rec, err)
			}
			return nil
		}},
		{"PromoteModelVersion", func(c *storecache.Store) error {
			entry, v, files := registryFixture("org/m1", "v2")
			if err := c.SetModelVersion(entry, v, files); err != nil {
				return err
			}
			c.GetModelRegistryRecord("org/m1") // re-warm so the promote is what invalidates
			return c.PromoteModelVersion("org/m1", "v2")
		}, func(rec *contracts.ModelRegistryRecord, err error) error {
			if err != nil || rec.ActiveVersion.Version != "v2" || rec.ActiveVersion.R2Prefix != "org/m1/v2" {
				return fmt.Errorf("rec=%+v err=%v", rec, err)
			}
			return nil
		}},
		{"SetModelStatus", func(c *storecache.Store) error {
			return c.SetModelStatus("org/m1", "retired")
		}, func(rec *contracts.ModelRegistryRecord, err error) error {
			if rec != nil || !errors.Is(err, contracts.ErrNotFound) {
				return fmt.Errorf("retired model still served: rec=%+v err=%v", rec, err)
			}
			return nil
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cached, counting, _ := newCachedMemoryStore(t)
			seedActiveModel(t, cached, "org/m1", "v1")
			cached.GetModelRegistryRecord("org/m1")
			cached.GetModelRegistryRecord("org/m1")
			if n := counting.count("GetModelRegistryRecord"); n != 1 {
				t.Fatalf("warm-up inner calls = %d, want 1", n)
			}
			if err := tc.mutate(cached); err != nil {
				t.Fatalf("mutate: %v", err)
			}
			before := counting.count("GetModelRegistryRecord")
			rec, err := cached.GetModelRegistryRecord("org/m1")
			if err := tc.check(rec, err); err != nil {
				t.Fatalf("stale read after %s: %v", tc.name, err)
			}
			if got := counting.count("GetModelRegistryRecord"); got != before+1 {
				t.Fatalf("inner reads after %s = %d, want %d", tc.name, got, before+1)
			}
			// Manifest follows the same entry.
			m, err := cached.GetModelManifest("org/m1")
			if rec == nil {
				if m != nil || !errors.Is(err, contracts.ErrNotFound) {
					t.Fatalf("manifest for retired model: %+v err=%v", m, err)
				}
			} else if err != nil || m.Version != rec.ActiveVersion.Version {
				t.Fatalf("manifest version %v vs record %v (err=%v)", m, rec.ActiveVersion.Version, err)
			}
		})
	}
}

func TestCachedStoreReturnsRecordCopies(t *testing.T) {
	cached, _, _ := newCachedMemoryStore(t)
	seedActiveModel(t, cached, "org/m1", "v1")

	r1, err := cached.GetModelRegistryRecord("org/m1")
	if err != nil {
		t.Fatal(err)
	}
	// Exactly what api/model_registry_handlers.go does before an upsert, plus
	// every other reference-typed field.
	r1.RuntimeParameters["reasoning_parser"] = "tampered"
	r1.RuntimeParameters["nested"].(map[string]any)["k"].([]any)[0] = "tampered"
	r1.Metadata["hugging_face_id"] = "tampered"
	r1.Capabilities[0] = "tampered"
	r1.Files[0].Path = "tampered"
	r1.ActiveVersion.Version = "tampered"
	r1.DisplayName = "tampered"

	r2, err := cached.GetModelRegistryRecord("org/m1")
	if err != nil {
		t.Fatal(err)
	}
	if r1 == r2 || r1.ActiveVersion == r2.ActiveVersion {
		t.Fatal("cache handed out the same pointer twice")
	}
	if r2.RuntimeParameters["reasoning_parser"] != "qwen3" ||
		r2.RuntimeParameters["nested"].(map[string]any)["k"].([]any)[0] != "a" ||
		r2.Metadata["hugging_face_id"] != "org/org/m1" ||
		r2.Capabilities[0] != "chat" ||
		r2.Files[0].Path != "config.json" ||
		r2.ActiveVersion.Version != "v1" ||
		r2.DisplayName != "Model org/m1" {
		t.Fatalf("caller mutation leaked into cache: %+v", r2)
	}

	// The structural clone must agree with the package's JSON-round-trip
	// clone (the existing oracle) on the same JSON-shaped data.
	oracle := recordutil.CloneModelRegistryEntry(&r2.ModelRegistryEntry)
	if fmt.Sprint(oracle.RuntimeParameters) != fmt.Sprint(r2.RuntimeParameters) ||
		fmt.Sprint(oracle.Metadata) != fmt.Sprint(r2.Metadata) {
		t.Fatalf("structural clone diverges from JSON clone:\n%v\n%v", oracle.RuntimeParameters, r2.RuntimeParameters)
	}
}

func TestCachedStoreTransientErrorsNotCached(t *testing.T) {
	for _, transient := range []error{
		errors.New("dial tcp: connection refused"),
		fmt.Errorf("store: user not found: %w", context.DeadlineExceeded), // Postgres wording for a timeout
	} {
		cached, counting, _ := newCachedMemoryStore(t)
		testfixture.SeedUser(t, cached, "acct-1")
		seedActiveModel(t, cached, "org/m1", "v1")
		counting.failWith = transient

		for i := 0; i < 3; i++ {
			if _, err := cached.GetUserByAccountID("acct-1"); !errors.Is(err, transient) {
				t.Fatalf("user get %d: err=%v", i, err)
			}
			if _, err := cached.GetModelRegistryRecord("org/m1"); !errors.Is(err, transient) {
				t.Fatalf("model get %d: err=%v", i, err)
			}
		}
		if n := counting.count("GetUserByAccountID"); n != 3 {
			t.Fatalf("transient user error was cached: inner calls %d, want 3", n)
		}
		if n := counting.count("GetModelRegistryRecord"); n != 3 {
			t.Fatalf("transient model error was cached: inner calls %d, want 3", n)
		}
		if st := cached.Stats(); st.Users.Entries != 0 || st.Models.Entries != 0 {
			t.Fatalf("transient errors populated the cache: %+v", st)
		}

		// Recovery: once the inner store answers again the value is cached.
		counting.failWith = nil
		if u, err := cached.GetUserByAccountID("acct-1"); err != nil || u.AccountID != "acct-1" {
			t.Fatalf("recovered get: %+v %v", u, err)
		}
	}
}

func TestCachedStoreColdLookupsPassThroughUncached(t *testing.T) {
	cached, _, _ := newCachedMemoryStore(t)
	testfixture.SeedUser(t, cached, "acct-1")
	if err := cached.SetUserStripeAccount("acct-1", "acct_x", "ready", "US", "bank", "0001", false); err != nil {
		t.Fatal(err)
	}
	if u, err := cached.GetUserByEmail("acct-1@example.test"); err != nil || u.AccountID != "acct-1" {
		t.Fatalf("GetUserByEmail: %+v %v", u, err)
	}
	if u, err := cached.GetUserByStripeAccount("acct_x"); err != nil || u.AccountID != "acct-1" {
		t.Fatalf("GetUserByStripeAccount: %+v %v", u, err)
	}
	if st := cached.Stats(); st.Users.Entries != 0 || st.Users.Hits+st.Users.Misses != 0 {
		t.Fatalf("cold lookups touched the cache: %+v", st.Users)
	}
}

// TestCachedStoreForwardsProfilerMethods pins that the decorator forwards the
// six profiler methods the Store interface gained in #809 (request profiles,
// fleet snapshots, telemetry pruning) to the wrapped store: CachedStore embeds
// Store and overrides none of them, so a write through the wrapper lands in
// the inner store and reads back through the wrapper.
func TestCachedStoreForwardsProfilerMethods(t *testing.T) {
	inner := memory.New(contracts.Config{})
	cached := storecache.New(inner, storecache.DefaultCacheConfig())
	var _ contracts.Store = cached // the wrapper satisfies the full interface, #809's methods included

	old := time.Now().Add(-2 * time.Hour)
	recent := time.Now()
	if err := cached.RecordRequestProfiles([]*contracts.RequestProfileRecord{
		{RequestID: "req-old", Attempt: 0, CreatedAt: old},
		{RequestID: "req-new", Attempt: 0, CreatedAt: recent},
	}); err != nil {
		t.Fatalf("RecordRequestProfiles through the wrapper: %v", err)
	}
	if got := cached.RequestProfilesSince(time.Time{}); len(got) != 2 {
		t.Fatalf("RequestProfilesSince(zero) = %d rows, want 2", len(got))
	}
	if got := cached.RequestProfilesSinceFiltered(recent.Add(-time.Minute), contracts.RequestProfileFilter{}); len(got) != 1 || got[0].RequestID != "req-new" {
		t.Fatalf("RequestProfilesSinceFiltered(recent) = %+v, want only req-new", got)
	}
	if err := cached.RecordFleetSnapshots([]contracts.FleetSnapshotRow{
		{SampledAt: old, ProviderID: "p-old", Model: "m"},
		{SampledAt: recent, ProviderID: "p-new", Model: "m"},
	}); err != nil {
		t.Fatalf("RecordFleetSnapshots through the wrapper: %v", err)
	}
	if got := cached.FleetSnapshotsSince(time.Time{}); len(got) != 2 {
		t.Fatalf("FleetSnapshotsSince(zero) = %d rows, want 2", len(got))
	}
	// The rows live in the inner store; the wrapper keeps nothing of its own.
	if got := inner.RequestProfilesSince(time.Time{}); len(got) != 2 {
		t.Fatalf("inner RequestProfilesSince = %d rows, want 2", len(got))
	}
	if got := inner.FleetSnapshotsSince(time.Time{}); len(got) != 2 {
		t.Fatalf("inner FleetSnapshotsSince = %d rows, want 2", len(got))
	}

	cutoff := recent.Add(-time.Hour)
	deleted, err := cached.PruneTelemetry(context.Background(), cutoff, cutoff, 100)
	if err != nil || deleted != 2 {
		t.Fatalf("PruneTelemetry through the wrapper = (%d, %v), want (2, nil)", deleted, err)
	}
	if got := cached.RequestProfilesSince(time.Time{}); len(got) != 1 || got[0].RequestID != "req-new" {
		t.Fatalf("after prune RequestProfilesSince = %+v, want only req-new", got)
	}
	if got := cached.FleetSnapshotsSince(time.Time{}); len(got) != 1 || got[0].ProviderID != "p-new" {
		t.Fatalf("after prune FleetSnapshotsSince = %+v, want only p-new", got)
	}
}
