package store

import "time"

// CachedStore is a read-through cache decorator over Store. It overrides only
// the lookups that sit on the inference hot path and are otherwise a Postgres
// round trip per call:
//
//   - GetUserByAccountID / GetUserByPrivyID (requireAuth on every request;
//     handleCompleteAt on every settlement)
//   - GetModelRegistryRecord / GetModelManifest (3-4 calls per chat request;
//     the Postgres implementation issues two queries each)
//
// Every other method is delegated untouched via the embedded Store, including
// the cold admin lookups GetUserByEmail and GetUserByStripeAccount.
//
// Consistency model -- SINGLE-PROCESS ASSUMPTION. Invalidation is in-process:
// each Store mutator that can change a cached value (the four *User* writers,
// the four model-registry writers) clears its whole domain after the inner
// write, and a generation counter rejects loads that raced with that write.
// This is only exact because one coordinator process serves every admin and
// publish mutation. Anything written to the database out of band -- a manual
// SQL edit, or a second coordinator sharing the DB during a blue-green cutover
// -- is invisible until the TTL expires. The TTLs are therefore the staleness
// bound for out-of-band writes, not the primary invalidation mechanism.
//
// A miss that the inner store reports as ErrNotFound is cached for
// NegativeTTL; alias names reach GetModelRegistryRecord on every request and
// would otherwise miss every time. Any other error is passed through uncached.
// Returned values are deep copies; the cached value is never handed out.
type CachedStore struct {
	Store
	users  *domainCache[User]
	models *domainCache[ModelRegistryRecord]
}

// CacheConfig tunes CachedStore. Zero fields take DefaultCacheConfig values.
type CacheConfig struct {
	// UserTTL bounds staleness of a user's Role / PlatformFeePercent / Stripe
	// fields after an out-of-band write. In-process writes invalidate at once.
	UserTTL time.Duration
	// ModelTTL bounds staleness of a model's active version and files. Kept
	// tighter than UserTTL because a promoted version changes what providers
	// are told to download.
	ModelTTL time.Duration
	// NegativeTTL bounds how long an ErrNotFound result is remembered. Short,
	// so an entity created out of band appears quickly; in-process creation
	// invalidates at once.
	NegativeTTL time.Duration
	// MaxUsers / MaxModels cap each domain's entry count (random eviction).
	MaxUsers  int
	MaxModels int
	// Now is the clock; nil means time.Now. Tests inject a fake clock.
	Now func() time.Time
}

// DefaultCacheConfig is the production tuning: users 30s, model records 10s,
// negative entries 5s, 10k users and 1k models resident.
func DefaultCacheConfig() CacheConfig {
	return CacheConfig{
		UserTTL:     30 * time.Second,
		ModelTTL:    10 * time.Second,
		NegativeTTL: 5 * time.Second,
		MaxUsers:    10_000,
		MaxModels:   1_000,
	}
}

func (c CacheConfig) withDefaults() CacheConfig {
	d := DefaultCacheConfig()
	if c.UserTTL <= 0 {
		c.UserTTL = d.UserTTL
	}
	if c.ModelTTL <= 0 {
		c.ModelTTL = d.ModelTTL
	}
	if c.NegativeTTL <= 0 {
		c.NegativeTTL = d.NegativeTTL
	}
	if c.MaxUsers <= 0 {
		c.MaxUsers = d.MaxUsers
	}
	if c.MaxModels <= 0 {
		c.MaxModels = d.MaxModels
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	return c
}

// NewCached wraps inner (memory or Postgres) with the read-through cache.
func NewCached(inner Store, cfg CacheConfig) *CachedStore {
	cfg = cfg.withDefaults()
	return &CachedStore{
		Store:  inner,
		users:  newDomainCache[User](cfg.UserTTL, cfg.NegativeTTL, cfg.MaxUsers, cfg.Now),
		models: newDomainCache[ModelRegistryRecord](cfg.ModelTTL, cfg.NegativeTTL, cfg.MaxModels, cfg.Now),
	}
}

// Unwrap exposes the wrapped backend so As can discover optional capabilities
// (durable push budgets, paged verification listing) that the static Store
// method set does not carry.
func (c *CachedStore) Unwrap() Store { return c.Store }

// Compile-time checks: the decorator still satisfies the full Store, and it
// is transparent to store.As.
var (
	_ Store     = (*CachedStore)(nil)
	_ Unwrapper = (*CachedStore)(nil)
)

// CacheCounters is one domain's counters since process start.
type CacheCounters struct {
	Hits          uint64 `json:"hits"`
	Misses        uint64 `json:"misses"`
	NegativeHits  uint64 `json:"negative_hits"`
	Evictions     uint64 `json:"evictions"`
	Invalidations uint64 `json:"invalidations"`
	Entries       int    `json:"entries"`
}

// CacheStats is a point-in-time snapshot of both domains.
type CacheStats struct {
	Users  CacheCounters `json:"users"`
	Models CacheCounters `json:"models"`
}

// Stats returns hit/miss/eviction counters for both domains.
func (c *CachedStore) Stats() CacheStats {
	return CacheStats{Users: c.users.counters(), Models: c.models.counters()}
}

// --- Users: cached lookups ---

func (c *CachedStore) GetUserByAccountID(accountID string) (*User, error) {
	return c.users.get("account\x00"+accountID, func() (*User, error) {
		return c.Store.GetUserByAccountID(accountID)
	}, cloneUser)
}

func (c *CachedStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	return c.users.get("privy\x00"+privyUserID, func() (*User, error) {
		return c.Store.GetUserByPrivyID(privyUserID)
	}, cloneUser)
}

// --- Users: every writer of the users table invalidates the whole domain.
// Invalidation happens even when the inner write fails: GetOrCreateUser
// re-reads by Privy ID after a duplicate-key CreateUser and must not be served
// the negative entry it just recorded.

func (c *CachedStore) CreateUser(user *User) error {
	err := c.Store.CreateUser(user)
	c.users.invalidate()
	return err
}

func (c *CachedStore) SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error {
	err := c.Store.SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4, instantEligible)
	c.users.invalidate()
	return err
}

func (c *CachedStore) SetUserRole(accountID, role string) error {
	err := c.Store.SetUserRole(accountID, role)
	c.users.invalidate()
	return err
}

func (c *CachedStore) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
	err := c.Store.SetUserPlatformFeePercent(accountID, feePercent)
	c.users.invalidate()
	return err
}

// --- Model registry: cached lookups ---

func (c *CachedStore) GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error) {
	return c.models.get(modelID, func() (*ModelRegistryRecord, error) {
		return c.Store.GetModelRegistryRecord(modelID)
	}, cloneModelRegistryRecord)
}

// GetModelManifest is derived from the cached record exactly as both inner
// implementations derive it (manifestFromRecord builds a fresh value that
// aliases nothing), so it needs no second cache and no defensive clone.
func (c *CachedStore) GetModelManifest(modelID string) (*ModelManifest, error) {
	rec, err := c.models.get(modelID, func() (*ModelRegistryRecord, error) {
		return c.Store.GetModelRegistryRecord(modelID)
	}, func(r *ModelRegistryRecord) *ModelRegistryRecord { return r })
	if err != nil {
		return nil, err
	}
	return manifestFromRecord(rec), nil
}

// --- Model registry: every writer that can change an active record (entry
// fields, versions and their files, the active-version pointer, status)
// invalidates the whole domain. Alias and publishing-key writers are left
// alone: the record query joins only model_registry, model_active_versions and
// model_versions.

func (c *CachedStore) UpsertModelRegistryEntry(entry *ModelRegistryEntry) error {
	err := c.Store.UpsertModelRegistryEntry(entry)
	c.models.invalidate()
	return err
}

func (c *CachedStore) SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error {
	err := c.Store.SetModelVersion(entry, version, files)
	c.models.invalidate()
	return err
}

func (c *CachedStore) PromoteModelVersion(modelID, version string) error {
	err := c.Store.PromoteModelVersion(modelID, version)
	c.models.invalidate()
	return err
}

func (c *CachedStore) SetModelStatus(modelID, status string) error {
	err := c.Store.SetModelStatus(modelID, status)
	c.models.invalidate()
	return err
}
