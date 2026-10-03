package store

import (
	"sync"
	"testing"
	"time"
)

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
}
