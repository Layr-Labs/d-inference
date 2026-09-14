package cache

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/testfixture"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

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
	c := New(memory.New(contracts.Config{}), CacheConfig{})
	testfixture.SeedUser(t, c, "acct-1")
	if _, err := c.GetUserByAccountID("acct-1"); err != nil {
		t.Fatal(err)
	}
	if c.Stats().Users.Entries != 1 {
		t.Fatal("zero-config cache did not store")
	}
}
