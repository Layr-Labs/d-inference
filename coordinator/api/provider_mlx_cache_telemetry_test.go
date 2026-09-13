package api

import (
	"fmt"
	"log/slog"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

var uuidShaped = regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)

// packetTags returns the DogStatsD tags of one wire line (after "|#").
func packetTags(line string) []string {
	i := strings.Index(line, "|#")
	if i < 0 {
		return nil
	}
	return strings.Split(line[i+2:], ",")
}

func containsTag(line, tag string) bool {
	for _, t := range packetTags(line) {
		if t == tag {
			return true
		}
	}
	return false
}

// assertBoundedTags fails if any emitted line carries a provider id or a
// UUID-shaped tag value, or lacks the two bounded tags.
func assertBoundedTags(t *testing.T, packets []string) {
	t.Helper()
	for _, p := range packets {
		for _, tag := range packetTags(p) {
			if strings.HasPrefix(tag, "provider_id:") {
				t.Fatalf("provider_id tag emitted: %s", p)
			}
			if uuidShaped.MatchString(tag) {
				t.Fatalf("UUID-shaped tag value emitted: %s", p)
			}
		}
		if !containsTag(p, "chip_family:M3") || !containsTag(p, "provider_version:0.8.x") {
			t.Fatalf("bounded tags missing: %s", p)
		}
	}
}

func newMLXTelemetryProvider(t *testing.T, reg *registry.Registry, id, chipFamily, version string) *registry.Provider {
	t.Helper()
	p := makeRoutableProvider(t, reg, id, "test-model")
	p.Mu().Lock()
	p.Hardware.ChipFamily = chipFamily
	p.Version = version
	p.Mu().Unlock()
	return p
}

func mlxCapacity(sweeps, reclaims, reclaimedBytes uint64) *protocol.BackendCapacity {
	return &protocol.BackendCapacity{
		GPUMemoryActiveGB: 8,
		GPUMemoryPeakGB:   12,
		GPUMemoryCacheGB:  2,
		MLXCacheReclaimer: &protocol.MLXCacheReclaimerTelemetry{
			CacheLimitBytes:       1 << 30,
			SweepSignals:          sweeps,
			Reclaims:              reclaims,
			ReclaimedBytes:        reclaimedBytes,
			LastReclaimedBytes:    2048,
			LastReclaimDurationMS: 3,
		},
	}
}

// TestMLXCacheTelemetryBoundedTagsAndDeltas walks the heartbeat sequence a
// provider session produces — first observation, a reclaim, no change, a
// counter reset — and checks that every emitted line (histograms and counts)
// carries only the bounded tags, never the session UUID, and that the
// cumulative reclaimer counters surface as per-heartbeat deltas.
func TestMLXCacheTelemetryBoundedTagsAndDeltas(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)
	// Counts are aggregated client-side by datadog-go; force them onto the
	// wire before reading the collector.
	flushAndDrain := func() []string {
		_ = ddClient.Statsd.Flush()
		return collector.drain()
	}

	provider := newMLXTelemetryProvider(t, reg, uuid.New().String(), "M3", "0.8.20")

	// 1. First heartbeat of the session: no baseline → point-in-time
	// histograms only, no deltas, no last_* samples.
	first := mlxCapacity(5, 2, 4096)
	srv.recordMLXCacheTelemetry(provider, nil, first)
	packets := flushAndDrain()
	assertBoundedTags(t, packets)
	for _, want := range []string{
		"provider.mlx_memory.active_gb:8|h", "provider.mlx_memory.peak_gb:12|h",
		"provider.mlx_memory.cache_gb:2|h", "provider.mlx_cache.limit_bytes:1073741824|h",
	} {
		if !hasMetric(packets, want) {
			t.Fatalf("first heartbeat: missing %q in %v", want, packets)
		}
	}
	for _, absent := range []string{"mlx_cache.reclaims", "mlx_cache.sweep_signals", "mlx_cache.reclaimed_bytes", "mlx_cache.last_"} {
		if hasMetric(packets, absent) {
			t.Fatalf("first heartbeat: %q emitted without a baseline: %v", absent, packets)
		}
	}

	// 2. A reclaim happened: deltas as counts + last_* samples.
	second := mlxCapacity(7, 3, 8192)
	srv.recordMLXCacheTelemetry(provider, first, second)
	packets = flushAndDrain()
	assertBoundedTags(t, packets)
	for _, want := range []string{
		"provider.mlx_cache.sweep_signals:2|c", "provider.mlx_cache.reclaims:1|c",
		"provider.mlx_cache.reclaimed_bytes:4096|c",
		"provider.mlx_cache.last_reclaimed_bytes:2048|h", "provider.mlx_cache.last_reclaim_duration_ms:3|h",
	} {
		if !hasMetric(packets, want) {
			t.Fatalf("reclaim heartbeat: missing %q in %v", want, packets)
		}
	}

	// 3. Nothing changed: memory histograms still flow, no counts, no last_*.
	srv.recordMLXCacheTelemetry(provider, second, second)
	packets = flushAndDrain()
	assertBoundedTags(t, packets)
	if !hasMetric(packets, "provider.mlx_memory.active_gb:8|h") {
		t.Fatalf("steady heartbeat: memory histogram missing: %v", packets)
	}
	for _, absent := range []string{"|c|", "mlx_cache.last_"} {
		if hasMetric(packets, absent) {
			t.Fatalf("steady heartbeat: unexpected %q in %v", absent, packets)
		}
	}

	// 4. Counters went backwards (provider-side reset): no counts.
	srv.recordMLXCacheTelemetry(provider, second, first)
	packets = flushAndDrain()
	assertBoundedTags(t, packets)
	if hasMetric(packets, "|c|") {
		t.Fatalf("reset heartbeat: a negative delta was emitted as a count: %v", packets)
	}

	// 5. No reclaimer block: memory histograms only.
	srv.recordMLXCacheTelemetry(provider, second, &protocol.BackendCapacity{GPUMemoryActiveGB: 8})
	packets = flushAndDrain()
	assertBoundedTags(t, packets)
	if hasMetric(packets, "mlx_cache") {
		t.Fatalf("reclaimer-less heartbeat emitted cache metrics: %v", packets)
	}
}

// TestMLXCacheTelemetryFleetCardinalityIsBounded reconnects many sessions
// (fresh UUIDs) across a few chip families and versions: the number of
// distinct tag sets must be the product of the bounded dimensions, not the
// number of sessions.
func TestMLXCacheTelemetryFleetCardinalityIsBounded(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)
	// Counts are aggregated client-side by datadog-go; force them onto the
	// wire before reading the collector.
	flushAndDrain := func() []string {
		_ = ddClient.Statsd.Flush()
		return collector.drain()
	}

	families := []string{"M3", "M4"}
	versions := []string{"0.8.20", "0.9.1"}
	const sessions = 40
	for i := 0; i < sessions; i++ {
		p := newMLXTelemetryProvider(t, reg, uuid.New().String(), families[i%2], versions[(i/2)%2])
		srv.recordMLXCacheTelemetry(p, mlxCapacity(1, 1, 1), mlxCapacity(2, 2, 2))
	}
	packets := flushAndDrain()
	if len(packets) < sessions {
		t.Fatalf("expected at least one line per session, got %d", len(packets))
	}
	tagSets := map[string]struct{}{}
	for _, p := range packets {
		tags := packetTags(p)
		for _, tag := range tags {
			if strings.HasPrefix(tag, "provider_id:") || uuidShaped.MatchString(tag) {
				t.Fatalf("session-scoped tag emitted: %s", p)
			}
		}
		sort.Strings(tags)
		tagSets[strings.Join(tags, ",")] = struct{}{}
	}
	if want := len(families) * len(versions); len(tagSets) != want {
		t.Fatalf("distinct tag sets = %d, want %d (bounded by chip_family × provider_version): %v", len(tagSets), want, tagSets)
	}
}

func TestMLXCacheTelemetryNoDatadogIsNoop(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	// No panic and no work without a Datadog client, including a nil provider.
	srv.recordMLXCacheTelemetry(nil, nil, mlxCapacity(1, 1, 1))
	// A bare Server (tests that never run NewServer) and a nil capacity are
	// both valid during rollout.
	bare := &Server{}
	bare.recordMLXCacheTelemetry(nil, nil, nil)
	bare.recordMLXCacheTelemetry(nil, nil, &protocol.BackendCapacity{GPUMemoryActiveGB: 1})
}

func TestSanitizeChipFamilyTag(t *testing.T) {
	cases := map[string]string{
		"":                                      "unknown",
		"  ":                                    "unknown",
		"Unknown":                               "unknown",
		"M3":                                    "M3",
		" M4 Pro ":                              "M4_Pro",
		"m5":                                    "other",
		"M3;drop":                               "other",
		"M3,env:prod":                           "other",
		"Apple-M3":                              "other",
		"family-that-is-way-too-long-for-a-tag": "other",
		fmt.Sprintf("%017d", 0):                 "other",
	}
	for in, want := range cases {
		if got := sanitizeChipFamilyTag(in); got != want {
			t.Errorf("sanitizeChipFamilyTag(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCounterDelta(t *testing.T) {
	if got := counterDelta(5, 7); got != 2 {
		t.Fatalf("delta = %d, want 2", got)
	}
	if got := counterDelta(7, 5); got != 0 {
		t.Fatalf("backwards delta = %d, want 0", got)
	}
	if got := counterDelta(0, ^uint64(0)); got <= 0 {
		t.Fatalf("saturated delta = %d, want positive", got)
	}
}
