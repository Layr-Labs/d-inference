package storecache

import "time"

// Config tunes CachedStore. Zero fields take DefaultConfig values.
type Config struct {
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

// DefaultConfig is the production tuning: users 30s, model records 10s,
// negative entries 5s, 10k users and 1k models resident.
func DefaultConfig() Config {
	return Config{
		UserTTL:     30 * time.Second,
		ModelTTL:    10 * time.Second,
		NegativeTTL: 5 * time.Second,
		MaxUsers:    10_000,
		MaxModels:   1_000,
	}
}

func Resolve(c Config) Config {
	d := DefaultConfig()
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
