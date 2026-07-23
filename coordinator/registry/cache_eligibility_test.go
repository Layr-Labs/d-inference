package registry

import (
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func cacheEligibilityTestRegistry() *Registry {
	return New(slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestPrefixCacheTelemetryEnumCasingIsPinned(t *testing.T) {
	for name, test := range map[string]struct {
		got  []string
		want string
	}{
		"states": {
			got:  PrefixCacheStatusStates(),
			want: "ready,pending,disabled,error",
		},
		"reasons": {
			got: PrefixCacheStatusReasons(),
			want: "ready,config_disabled,no_loaded_slot,weight_hash_unavailable," +
				"runtime_identity_unavailable,unsupported_layout,unsupported_backend," +
				"paged_hybrid_unsupported,scan_pending,scan_failed,disk_unavailable,cache_init_failed",
		},
		"backends": {
			got: PrefixCacheStatusBackends(), want: "contiguous,paged,unknown",
		},
		"strategies": {
			got: PrefixCacheReplayStrategies(), want: "direct,frozen_full,none,unknown",
		},
		"donation outcomes": {
			got: PrefixCacheDonationOutcomes(),
			want: "donated,below_effective_token_floor,no_complete_block,lossy_snapshot," +
				"incomplete_layer_state,stage_size_exceeded,write_rate_limited,write_queue_full," +
				"already_durable,already_queued,cache_closed,disk_unavailable,write_failed",
		},
	} {
		t.Run(name, func(t *testing.T) {
			if got := strings.Join(test.got, ","); got != test.want {
				t.Fatalf("enum values=%q, want %q", got, test.want)
			}
		})
	}
}

func TestPrefixCacheTelemetrySanitizesOptionalCompatibility(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{{ID: "public-model"}})
	statuses := []protocol.PrefixCacheModelStatus{
		{
			ModelID: "owner-local", Backend: "unknown", ReplayStrategy: "none",
			State: "disabled", Reason: "config_disabled",
		},
		{
			ModelID: "future-model", Backend: "future_backend", ReplayStrategy: "future_strategy",
			State: "warming", Reason: "future_reason",
		},
		{
			ModelID: "not-advertised", Backend: "contiguous", ReplayStrategy: "direct",
			State: "ready", Reason: "ready",
		},
	}
	outcomes := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 7},
		{Outcome: "future_donation_outcome", Count: 9},
		{Outcome: "write_failed", Count: 0},
	}
	msg := protocol.RegisterMessage{
		Models: []protocol.ModelInfo{
			{ID: "owner-local"},
			{ID: "future-model"},
		},
		PrefixCacheStatuses:         &statuses,
		PrefixCacheDonationOutcomes: &outcomes,
	}
	if err := reg.ValidatePrefixCacheRegistration(&msg); err != nil {
		t.Fatalf("optional telemetry closed owner-local registration: %v", err)
	}
	if msg.PrefixCacheStatuses == nil || len(*msg.PrefixCacheStatuses) != 1 ||
		(*msg.PrefixCacheStatuses)[0].ModelID != "owner-local" {
		t.Fatalf("status sanitization = %+v, want owner-local known entry", msg.PrefixCacheStatuses)
	}
	if msg.PrefixCacheDonationOutcomes == nil ||
		len(*msg.PrefixCacheDonationOutcomes) != 1 ||
		(*msg.PrefixCacheDonationOutcomes)[0].Outcome != "donated" {
		t.Fatalf("donation sanitization = %+v, want donated known entry", msg.PrefixCacheDonationOutcomes)
	}
	provider := reg.Register("owner", nil, &msg)
	if provider == nil {
		t.Fatal("owner-local provider was not registered")
	}
	aggregate := reg.PrefixCacheProtocolStatus()
	if aggregate.ReportedLoadedModels != 1 ||
		aggregate.ByReason["config_disabled"] != 1 {
		t.Fatalf("known owner-local aggregate = %+v", aggregate)
	}
}

func TestPrefixCacheTelemetryStructuralAbuseDropsWholeOptionalSnapshot(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	valid := protocol.PrefixCacheModelStatus{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "direct",
		State: "ready", Reason: "ready",
	}
	for _, test := range []struct {
		name     string
		statuses []protocol.PrefixCacheModelStatus
	}{
		{
			name:     "duplicate model ids",
			statuses: []protocol.PrefixCacheModelStatus{valid, valid},
		},
		{
			name: "blank model id",
			statuses: []protocol.PrefixCacheModelStatus{{
				Backend: "contiguous", ReplayStrategy: "direct", State: "ready", Reason: "ready",
			}},
		},
		{
			name: "non-canonical model id",
			statuses: []protocol.PrefixCacheModelStatus{{
				ModelID: " model ", Backend: "contiguous", ReplayStrategy: "direct",
				State: "ready", Reason: "ready",
			}},
		},
		{
			name:     "oversized",
			statuses: make([]protocol.PrefixCacheModelStatus, maxPrefixCacheStatuses+1),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			statuses := append([]protocol.PrefixCacheModelStatus(nil), test.statuses...)
			msg := protocol.RegisterMessage{
				Models:              []protocol.ModelInfo{{ID: "model"}},
				PrefixCacheStatuses: &statuses,
			}
			if err := reg.ValidatePrefixCacheRegistration(&msg); err != nil {
				t.Fatalf("structural optional telemetry closed registration: %v", err)
			}
			if msg.PrefixCacheStatuses == nil || len(*msg.PrefixCacheStatuses) != 0 {
				t.Fatalf("structural snapshot was not dropped: %+v", msg.PrefixCacheStatuses)
			}
		})
	}

	for _, test := range []struct {
		name     string
		outcomes []protocol.PrefixCacheDonationOutcomeCount
	}{
		{
			name: "duplicate outcomes",
			outcomes: []protocol.PrefixCacheDonationOutcomeCount{
				{Outcome: "donated", Count: 1},
				{Outcome: "donated", Count: 2},
			},
		},
		{
			name:     "oversized",
			outcomes: make([]protocol.PrefixCacheDonationOutcomeCount, maxPrefixCacheDonationOutcomes+1),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			outcomes := append([]protocol.PrefixCacheDonationOutcomeCount(nil), test.outcomes...)
			msg := protocol.RegisterMessage{
				Models:                      []protocol.ModelInfo{{ID: "model"}},
				PrefixCacheDonationOutcomes: &outcomes,
			}
			if err := reg.ValidatePrefixCacheRegistration(&msg); err != nil {
				t.Fatalf("structural optional telemetry closed registration: %v", err)
			}
			if msg.PrefixCacheDonationOutcomes == nil ||
				len(*msg.PrefixCacheDonationOutcomes) != 0 {
				t.Fatalf("structural outcome snapshot was not dropped: %+v", msg.PrefixCacheDonationOutcomes)
			}
		})
	}
}

func TestPrefixCacheTelemetryOmissionAndRoutingCapabilityStrictness(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	legacy := protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "model"}}}
	if err := reg.ValidatePrefixCacheRegistration(&legacy); err != nil {
		t.Fatal(err)
	}
	if legacy.PrefixCacheStatuses != nil || legacy.PrefixCacheDonationOutcomes != nil {
		t.Fatal("old-provider omission was converted into a reported snapshot")
	}

	badCapability := protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{{ID: "model"}},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{{
			ModelID: "not-advertised",
		}},
	}
	if err := reg.ValidatePrefixCacheRegistration(&badCapability); err == nil {
		t.Fatal("authoritative routing capability validation became fail-open")
	}
}

func TestPrefixCacheStatusReplacementClearDisconnectAndMixedOmission(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	statuses := []protocol.PrefixCacheModelStatus{
		{ModelID: "ready", Backend: "contiguous", ReplayStrategy: "direct", State: "ready", Reason: "ready"},
		{ModelID: "scan", Backend: "paged", ReplayStrategy: "unknown", State: "pending", Reason: "scan_pending"},
		{ModelID: "hash", Backend: "contiguous", ReplayStrategy: "frozen_full", State: "disabled", Reason: "weight_hash_unavailable"},
	}
	current := reg.Register("current", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 1,
		Models:              []protocol.ModelInfo{{ID: "ready"}, {ID: "scan"}, {ID: "hash"}},
		PrefixCacheStatuses: &statuses,
	})
	current.mu.Lock()
	current.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
		{Model: "ready", State: "idle"},
		{Model: "scan", State: "running"},
		{Model: "hash", State: "reloading"},
	}}
	current.mu.Unlock()
	legacy := reg.Register("legacy", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 1,
		Models:              []protocol.ModelInfo{{ID: "legacy"}},
	})
	legacy.mu.Lock()
	legacy.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
		Model: "legacy", State: "idle",
	}}}
	legacy.mu.Unlock()

	got := reg.PrefixCacheProtocolStatus()
	if got.LoadedModels != 4 || got.ReportedLoadedModels != 3 ||
		got.UnreportedLoadedModels != 1 || got.ExcludedModels != 2 ||
		got.ByState["ready"] != 1 ||
		got.ByReason["scan_pending"] != 1 ||
		got.ByReason["weight_hash_unavailable"] != 1 ||
		got.ByBackend["contiguous"] != 2 ||
		got.ByReplayStrategy["frozen_full"] != 1 {
		t.Fatalf("initial aggregate = %+v", got)
	}

	empty := []protocol.PrefixCacheModelStatus{}
	if err := reg.UpdatePrefixCacheTelemetry("current", &empty, nil); err != nil {
		t.Fatal(err)
	}
	if err := reg.UpdatePrefixCacheTelemetry("current", nil, nil); err != nil {
		t.Fatal(err)
	}
	got = reg.PrefixCacheProtocolStatus()
	if got.ReportedLoadedModels != 0 || got.UnreportedLoadedModels != 4 {
		t.Fatalf("authoritative clear/old omission aggregate = %+v", got)
	}

	replacement := []protocol.PrefixCacheModelStatus{statuses[0]}
	if err := reg.UpdatePrefixCacheTelemetry("current", &replacement, nil); err != nil {
		t.Fatal(err)
	}
	got = reg.PrefixCacheProtocolStatus()
	if got.ReportedLoadedModels != 1 || got.UnreportedLoadedModels != 3 {
		t.Fatalf("replacement aggregate = %+v", got)
	}

	reg.Disconnect("current")
	got = reg.PrefixCacheProtocolStatus()
	if got.LoadedModels != 1 || got.ReportedLoadedModels != 0 ||
		got.UnreportedLoadedModels != 1 {
		t.Fatalf("disconnect retained status = %+v", got)
	}
}

func TestPrefixCacheDonationDeltasAndModelUpdateCleanup(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{{ID: "old"}, {ID: "new"}})
	reg.SetModelAliases(map[string]AliasTarget{
		"public": {Desired: "new", Previous: "old"},
	})
	statuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "old", Backend: "contiguous", ReplayStrategy: "direct",
		State: "ready", Reason: "ready",
	}}
	baseline := []protocol.PrefixCacheDonationOutcomeCount{{
		Outcome: "donated", Count: 2,
	}}
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{
		Models:                      []protocol.ModelInfo{{ID: "old"}},
		PrefixCacheStatuses:         &statuses,
		PrefixCacheDonationOutcomes: &baseline,
	})
	reg.cacheRouting.mu.Lock()
	reg.cacheRouting.upsertHolderLocked("old-holder", cacheHolder{
		ProviderID: provider.ID, ModelID: "old",
		UpdatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Minute),
	})
	reg.cacheRouting.mu.Unlock()

	five := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 5},
		{Outcome: "future_outcome", Count: 99},
	}
	if err := reg.UpdatePrefixCacheTelemetry("provider", nil, &five); err != nil {
		t.Fatal(err)
	}
	if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"]; got != 3 {
		t.Fatalf("donation delta = %d, want 3", got)
	}
	oversized := make(
		[]protocol.PrefixCacheDonationOutcomeCount,
		maxPrefixCacheDonationOutcomes+1,
	)
	if err := reg.UpdatePrefixCacheTelemetry("provider", nil, &oversized); err != nil {
		t.Fatalf("oversized optional outcomes became fatal: %v", err)
	}
	if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"]; got != 3 {
		t.Fatalf("dropped structural snapshot changed aggregate: %d", got)
	}
	decreased := []protocol.PrefixCacheDonationOutcomeCount{{Outcome: "donated", Count: 1}}
	if err := reg.UpdatePrefixCacheTelemetry("provider", nil, &decreased); err != nil {
		t.Fatal(err)
	}
	four := []protocol.PrefixCacheDonationOutcomeCount{{Outcome: "donated", Count: 4}}
	if err := reg.UpdatePrefixCacheTelemetry("provider", nil, &four); err != nil {
		t.Fatal(err)
	}
	if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"]; got != 3 {
		t.Fatalf("counter rollback inflated central total: %d", got)
	}

	merged, dropped := reg.MergeProviderModels("provider", []protocol.ModelInfo{{ID: "new"}})
	if len(merged) != 1 || len(dropped) != 1 || dropped[0] != "old" {
		t.Fatalf("model update merged=%v dropped=%v", merged, dropped)
	}
	provider.mu.Lock()
	_, staleStatus := provider.PrefixCacheStatuses["old"]
	_, staleCapability := provider.PrefixCacheV2Models["old"]
	provider.mu.Unlock()
	if staleStatus || staleCapability {
		t.Fatal("model update retained stale cache state")
	}
	if got := reg.CacheRoutingLifecycleStatus().
		HolderRemoved[string(cacheHolderRemovalCapabilityChange)]; got != 1 {
		t.Fatalf("model update capability-change removals=%d, want 1", got)
	}
}
