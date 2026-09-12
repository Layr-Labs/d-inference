package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

// countingStore forwards every call to a real Store and counts the inner
// reads of the lookups CachedStore caches. It is not a mock of behavior: the
// wrapped store answers every call. failWith and afterLoad exist so tests can
// exercise the transient-error and read/write-race paths deterministically.
type countingStore struct {
	Store
	mu        sync.Mutex
	calls     map[string]int
	failWith  error  // when set, cached lookups return it instead of forwarding
	afterLoad func() // runs after the inner read, before returning (race test)
}

func newCountingStore(inner Store) *countingStore {
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

func (c *countingStore) GetUserByAccountID(accountID string) (*User, error) {
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

func (c *countingStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	c.note("GetUserByPrivyID")
	if c.failWith != nil {
		return nil, c.failWith
	}
	return c.Store.GetUserByPrivyID(privyUserID)
}

func (c *countingStore) GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error) {
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

func (c *countingStore) GetModelManifest(modelID string) (*ModelManifest, error) {
	c.note("GetModelManifest")
	return c.Store.GetModelManifest(modelID)
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)}
}

func (f *fakeClock) now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

func (f *fakeClock) advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

// newCachedMemoryStore composes CachedStore -> countingStore -> MemoryStore
// with a fake clock and the production TTLs.
func newCachedMemoryStore(t *testing.T) (*CachedStore, *countingStore, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	counting := newCountingStore(NewMemory(Config{}))
	cfg := DefaultCacheConfig()
	cfg.Now = clock.now
	return NewCached(counting, cfg), counting, clock
}

func seedUser(t *testing.T, st Store, accountID string) *User {
	t.Helper()
	u := &User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Email: accountID + "@example.test"}
	if err := st.CreateUser(u); err != nil {
		t.Fatalf("CreateUser(%s): %v", accountID, err)
	}
	return u
}

const cachedTestHash = "0000000000000000000000000000000000000000000000000000000000000000"

func registryFixture(modelID, version string) (*ModelRegistryEntry, *ModelVersion, []ModelVersionFile) {
	entry := &ModelRegistryEntry{
		ID: modelID, DisplayName: "Model " + modelID, Status: "active", MinRAMGB: 16,
		MaxContextLength: 32768, MaxOutputLength: 8192,
		Capabilities:                 []string{"chat"},
		RequiredProviderCapabilities: []string{},
		RuntimeParameters:            map[string]any{"reasoning_parser": "qwen3", "nested": map[string]any{"k": []any{"a", "b"}}},
		Metadata:                     map[string]any{"hugging_face_id": "org/" + modelID},
	}
	v := &ModelVersion{ModelID: modelID, Version: version, R2Prefix: modelID + "/" + version,
		AggregateSHA256: cachedTestHash, TotalSizeBytes: 3, FileCount: 1, Status: "ready"}
	files := []ModelVersionFile{{Path: "config.json", SizeBytes: 3, SHA256: cachedTestHash, Role: "config"}}
	return entry, v, files
}

// seedActiveModel registers and promotes one ready version so the model has
// an active registry record.
func seedActiveModel(t *testing.T, st Store, modelID, version string) {
	t.Helper()
	entry, v, files := registryFixture(modelID, version)
	if err := st.SetModelVersion(entry, v, files); err != nil {
		t.Fatalf("SetModelVersion(%s %s): %v", modelID, version, err)
	}
	if err := st.PromoteModelVersion(modelID, version); err != nil {
		t.Fatalf("PromoteModelVersion(%s %s): %v", modelID, version, err)
	}
}

// --- Users ---

func TestCachedStoreUserHitAfterMiss(t *testing.T) {
	cached, counting, _ := newCachedMemoryStore(t)
	seedUser(t, cached, "acct-1")

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
	seedUser(t, cached, "acct-1")

	cached.GetUserByAccountID("acct-1")
	clock.advance(DefaultCacheConfig().UserTTL - time.Second)
	cached.GetUserByAccountID("acct-1")
	if n := counting.count("GetUserByAccountID"); n != 1 {
		t.Fatalf("calls before expiry = %d, want 1", n)
	}
	clock.advance(2 * time.Second)
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
		if u != nil || !errors.Is(err, ErrNotFound) {
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

	clock.advance(DefaultCacheConfig().NegativeTTL + time.Millisecond)
	cached.GetUserByAccountID("ghost")
	if n := counting.count("GetUserByAccountID"); n != 2 {
		t.Fatalf("inner calls after negative TTL = %d, want 2", n)
	}
}

func TestCachedStoreUserMutatorsInvalidate(t *testing.T) {
	fee := int64(0)
	cases := []struct {
		name   string
		mutate func(*CachedStore) error
		check  func(*User) error
	}{
		{"CreateUser", func(c *CachedStore) error {
			return c.CreateUser(&User{AccountID: "acct-other", PrivyUserID: "did:privy:other"})
		}, func(*User) error { return nil }},
		{"SetUserRole", func(c *CachedStore) error {
			return c.SetUserRole("acct-1", RoleService)
		}, func(u *User) error {
			if u.Role != RoleService {
				return fmt.Errorf("role = %q, want %q", u.Role, RoleService)
			}
			return nil
		}},
		{"SetUserPlatformFeePercent", func(c *CachedStore) error {
			return c.SetUserPlatformFeePercent("acct-1", &fee)
		}, func(u *User) error {
			if u.PlatformFeePercent == nil || *u.PlatformFeePercent != 0 {
				return fmt.Errorf("fee = %v, want 0", u.PlatformFeePercent)
			}
			return nil
		}},
		{"SetUserStripeAccount", func(c *CachedStore) error {
			return c.SetUserStripeAccount("acct-1", "acct_stripe", "pending", "US", "card", "4242", true)
		}, func(u *User) error {
			if u.StripeAccountID != "acct_stripe" || u.StripeAccountStatus != "pending" {
				return fmt.Errorf("stripe = %q/%q, want acct_stripe/pending", u.StripeAccountID, u.StripeAccountStatus)
			}
			return nil
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cached, counting, _ := newCachedMemoryStore(t)
			seedUser(t, cached, "acct-1")
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

	if _, err := cached.GetUserByPrivyID("did:privy:new"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected miss, got %v", err)
	}
	seedUser(t, cached, "new") // CreateUser through the decorator
	if u, err := cached.GetUserByPrivyID("did:privy:new"); err != nil || u.AccountID != "new" {
		t.Fatalf("after create: user=%+v err=%v", u, err)
	}

	// Warm, then a duplicate CreateUser fails -- it must still invalidate.
	cached.GetUserByPrivyID("did:privy:new")
	n := counting.count("GetUserByPrivyID")
	if err := cached.CreateUser(&User{AccountID: "new", PrivyUserID: "did:privy:new"}); err == nil {
		t.Fatal("duplicate CreateUser should fail")
	}
	cached.GetUserByPrivyID("did:privy:new")
	if got := counting.count("GetUserByPrivyID"); got != n+1 {
		t.Fatalf("failed CreateUser did not invalidate: inner calls %d, want %d", got, n+1)
	}
}

func TestCachedStoreReturnsUserCopies(t *testing.T) {
	cached, _, _ := newCachedMemoryStore(t)
	seedUser(t, cached, "acct-1")
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

// --- Model registry ---

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
	clock.advance(DefaultCacheConfig().ModelTTL - time.Second)
	cached.GetModelRegistryRecord("org/m1")
	if n := counting.count("GetModelRegistryRecord"); n != 1 {
		t.Fatalf("calls before expiry = %d, want 1", n)
	}
	clock.advance(2 * time.Second)
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
		if _, err := cached.GetModelRegistryRecord("qwen3-alias"); !errors.Is(err, ErrNotFound) || err.Error() != want {
			t.Fatalf("record %d: err=%v want ErrNotFound %q", i, err, want)
		}
		if _, err := cached.GetModelManifest("qwen3-alias"); !errors.Is(err, ErrNotFound) || err.Error() != want {
			t.Fatalf("manifest %d: err=%v want ErrNotFound %q", i, err, want)
		}
	}
	if n := counting.count("GetModelRegistryRecord"); n != 1 {
		t.Fatalf("inner calls for a cached miss = %d, want 1", n)
	}
	clock.advance(DefaultCacheConfig().NegativeTTL + time.Millisecond)
	cached.GetModelRegistryRecord("qwen3-alias")
	if n := counting.count("GetModelRegistryRecord"); n != 2 {
		t.Fatalf("inner calls after negative TTL = %d, want 2", n)
	}
}

func TestCachedStoreModelMutatorsInvalidate(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*CachedStore) error
		check  func(*ModelRegistryRecord, error) error
	}{
		{"UpsertModelRegistryEntry", func(c *CachedStore) error {
			entry, _, _ := registryFixture("org/m1", "v1")
			entry.DisplayName = "Renamed"
			entry.RuntimeParameters["reasoning_parser"] = "gemma"
			return c.UpsertModelRegistryEntry(entry)
		}, func(rec *ModelRegistryRecord, err error) error {
			if err != nil || rec.DisplayName != "Renamed" || rec.RuntimeParameters["reasoning_parser"] != "gemma" {
				return fmt.Errorf("rec=%+v err=%v", rec, err)
			}
			return nil
		}},
		{"SetModelVersion", func(c *CachedStore) error {
			entry, v, files := registryFixture("org/m1", "v2")
			entry.MaxOutputLength = 16384
			return c.SetModelVersion(entry, v, files)
		}, func(rec *ModelRegistryRecord, err error) error {
			// v2 is uploaded but not promoted: entry fields changed, active stays v1.
			if err != nil || rec.MaxOutputLength != 16384 || rec.ActiveVersion.Version != "v1" {
				return fmt.Errorf("rec=%+v err=%v", rec, err)
			}
			return nil
		}},
		{"PromoteModelVersion", func(c *CachedStore) error {
			entry, v, files := registryFixture("org/m1", "v2")
			if err := c.SetModelVersion(entry, v, files); err != nil {
				return err
			}
			c.GetModelRegistryRecord("org/m1") // re-warm so the promote is what invalidates
			return c.PromoteModelVersion("org/m1", "v2")
		}, func(rec *ModelRegistryRecord, err error) error {
			if err != nil || rec.ActiveVersion.Version != "v2" || rec.ActiveVersion.R2Prefix != "org/m1/v2" {
				return fmt.Errorf("rec=%+v err=%v", rec, err)
			}
			return nil
		}},
		{"SetModelStatus", func(c *CachedStore) error {
			return c.SetModelStatus("org/m1", "retired")
		}, func(rec *ModelRegistryRecord, err error) error {
			if rec != nil || !errors.Is(err, ErrNotFound) {
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
				if m != nil || !errors.Is(err, ErrNotFound) {
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
	oracle := cloneModelRegistryEntry(&r2.ModelRegistryEntry)
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
		seedUser(t, cached, "acct-1")
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
	seedUser(t, cached, "acct-1")
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

func TestCacheConfigDefaults(t *testing.T) {
	cfg := CacheConfig{}.withDefaults()
	def := DefaultCacheConfig()
	if cfg.UserTTL != def.UserTTL || cfg.ModelTTL != def.ModelTTL || cfg.NegativeTTL != def.NegativeTTL ||
		cfg.MaxUsers != def.MaxUsers || cfg.MaxModels != def.MaxModels || cfg.Now == nil {
		t.Fatalf("defaults not applied: %+v", cfg)
	}
	if def.ModelTTL >= def.UserTTL || def.NegativeTTL > def.ModelTTL {
		t.Fatalf("expected negative <= model < user TTL ordering, got %+v", def)
	}
	// Zero-config wrapping must produce a working cache.
	c := NewCached(NewMemory(Config{}), CacheConfig{})
	seedUser(t, c, "acct-1")
	if _, err := c.GetUserByAccountID("acct-1"); err != nil {
		t.Fatal(err)
	}
	if c.Stats().Users.Entries != 1 {
		t.Fatal("zero-config cache did not store")
	}
}

// --- Profiler methods (#809) ---

// TestCachedStoreForwardsProfilerMethods pins that the decorator forwards the
// six profiler methods the Store interface gained in #809 (request profiles,
// fleet snapshots, telemetry pruning) to the wrapped store: CachedStore embeds
// Store and overrides none of them, so a write through the wrapper lands in
// the inner store and reads back through the wrapper.
func TestCachedStoreForwardsProfilerMethods(t *testing.T) {
	inner := NewMemory(Config{})
	cached := NewCached(inner, DefaultCacheConfig())
	var _ Store = cached // the wrapper satisfies the full interface, #809's methods included

	old := time.Now().Add(-2 * time.Hour)
	recent := time.Now()
	if err := cached.RecordRequestProfiles([]*RequestProfileRecord{
		{RequestID: "req-old", Attempt: 0, CreatedAt: old},
		{RequestID: "req-new", Attempt: 0, CreatedAt: recent},
	}); err != nil {
		t.Fatalf("RecordRequestProfiles through the wrapper: %v", err)
	}
	if got := cached.RequestProfilesSince(time.Time{}); len(got) != 2 {
		t.Fatalf("RequestProfilesSince(zero) = %d rows, want 2", len(got))
	}
	if got := cached.RequestProfilesSinceFiltered(recent.Add(-time.Minute), RequestProfileFilter{}); len(got) != 1 || got[0].RequestID != "req-new" {
		t.Fatalf("RequestProfilesSinceFiltered(recent) = %+v, want only req-new", got)
	}
	if err := cached.RecordFleetSnapshots([]FleetSnapshotRow{
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
