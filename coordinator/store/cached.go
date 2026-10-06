package store

import "github.com/eigeninference/d-inference/coordinator/internal/store/storecache"

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
	users  *storecache.Domain[User]
	models *storecache.Domain[ModelRegistryRecord]
}

// CacheConfig tunes the read-through cache. Zero fields use production defaults.
type CacheConfig = storecache.Config

// DefaultCacheConfig returns the production cache limits and lifetimes.
func DefaultCacheConfig() CacheConfig { return storecache.DefaultConfig() }

// NewCached wraps inner (memory or Postgres) with the read-through cache.
func NewCached(inner Store, cfg CacheConfig) *CachedStore {
	cfg = storecache.Resolve(cfg)
	return &CachedStore{
		Store:  inner,
		users:  storecache.New[User](cfg.UserTTL, cfg.NegativeTTL, cfg.MaxUsers, cfg.Now, ErrNotFound),
		models: storecache.New[ModelRegistryRecord](cfg.ModelTTL, cfg.NegativeTTL, cfg.MaxModels, cfg.Now, ErrNotFound),
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

// CacheCounters reports one domain's cache activity since process start.
type CacheCounters = storecache.Counters

// CacheStats is a point-in-time snapshot of both domains.
type CacheStats struct {
	Users  CacheCounters `json:"users"`
	Models CacheCounters `json:"models"`
}

// Stats returns hit/miss/eviction counters for both domains.
func (c *CachedStore) Stats() CacheStats {
	return CacheStats{Users: c.users.Counters(), Models: c.models.Counters()}
}

func (c *CachedStore) GetUserByAccountID(accountID string) (*User, error) {
	return c.users.Get("account\x00"+accountID, func() (*User, error) {
		return c.Store.GetUserByAccountID(accountID)
	}, cloneUser)
}

func (c *CachedStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	return c.users.Get("privy\x00"+privyUserID, func() (*User, error) {
		return c.Store.GetUserByPrivyID(privyUserID)
	}, cloneUser)
}

// Every user writer invalidates the domain even when the write fails:
// duplicate-key recovery must not receive a cached negative lookup.
func (c *CachedStore) CreateUser(user *User) error {
	err := c.Store.CreateUser(user)
	c.users.Invalidate()
	return err
}

func (c *CachedStore) SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error {
	err := c.Store.SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4, instantEligible)
	c.users.Invalidate()
	return err
}

func (c *CachedStore) SetUserRole(accountID, role string) error {
	err := c.Store.SetUserRole(accountID, role)
	c.users.Invalidate()
	return err
}

func (c *CachedStore) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
	err := c.Store.SetUserPlatformFeePercent(accountID, feePercent)
	c.users.Invalidate()
	return err
}

func (c *CachedStore) GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error) {
	return c.models.Get(modelID, func() (*ModelRegistryRecord, error) {
		return c.Store.GetModelRegistryRecord(modelID)
	}, cloneModelRegistryRecord)
}

// GetModelManifest is derived from the cached record exactly as both inner
// implementations derive it (manifestFromRecord builds a fresh value that
// aliases nothing), so it needs no second cache and no defensive clone.
func (c *CachedStore) GetModelManifest(modelID string) (*ModelManifest, error) {
	rec, err := c.models.Get(modelID, func() (*ModelRegistryRecord, error) {
		return c.Store.GetModelRegistryRecord(modelID)
	}, func(r *ModelRegistryRecord) *ModelRegistryRecord { return r })
	if err != nil {
		return nil, err
	}
	return ManifestFromRecord(rec), nil
}

// Writers that can change the active record invalidate the model domain.
// Alias and publishing-key writes do not affect the record query.
func (c *CachedStore) UpsertModelRegistryEntry(entry *ModelRegistryEntry) error {
	err := c.Store.UpsertModelRegistryEntry(entry)
	c.models.Invalidate()
	return err
}

func (c *CachedStore) SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error {
	err := c.Store.SetModelVersion(entry, version, files)
	c.models.Invalidate()
	return err
}

func (c *CachedStore) SetExistingModelVersion(version *ModelVersion, files []ModelVersionFile) error {
	err := c.Store.SetExistingModelVersion(version, files)
	c.models.Invalidate()
	return err
}

func (c *CachedStore) PromoteModelVersion(modelID, version string) error {
	err := c.Store.PromoteModelVersion(modelID, version)
	c.models.Invalidate()
	return err
}

func (c *CachedStore) RetireModelVersion(modelID, version string) error {
	err := c.Store.RetireModelVersion(modelID, version)
	c.models.Invalidate()
	return err
}

func (c *CachedStore) SetModelStatus(modelID, status string) error {
	err := c.Store.SetModelStatus(modelID, status)
	c.models.Invalidate()
	return err
}
