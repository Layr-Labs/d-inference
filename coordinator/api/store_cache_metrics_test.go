package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The cache counters must reach DogStatsD, tagged by domain, so the hit ratio
// is observable in production; a bare (unwrapped) store emits nothing.
func TestEmitStoreCacheGauges(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	collector := newUDPCollector(t)
	defer collector.Close()

	cached := store.NewCached(store.NewMemory(store.Config{}), store.DefaultCacheConfig())
	if err := cached.CreateUser(&store.User{AccountID: "acct-gauge", PrivyUserID: "did:privy:gauge"}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := cached.GetUserByAccountID("acct-gauge"); err != nil {
			t.Fatal(err)
		}
	}

	srv := NewServer(registry.New(logger), cached, ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.emitStoreCacheGauges()
	ddClient.Statsd.Flush()
	packets := collector.drain()

	for _, want := range []string{
		"store.cache.hits:2|g|#",
		"store.cache.misses:1|g|#",
		"domain:users",
		"domain:models",
		"store.cache.invalidations",
		"store.cache.entries",
	} {
		if !hasMetric(packets, want) {
			t.Errorf("missing %q in %v", want, packets)
		}
	}

	// Unwrapped store: nothing emitted, no panic.
	bare := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	bare.SetDatadog(ddClient)
	bare.emitStoreCacheGauges()
	ddClient.Statsd.Flush()
	if got := findMetrics(collector.drain(), "store.cache."); len(got) != 0 {
		t.Errorf("bare store emitted %v", got)
	}
}
