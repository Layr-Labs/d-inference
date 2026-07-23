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

func TestPrefixCacheStatusValidationRejectsUnboundedOrAmbiguousSnapshots(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{{ID: "model"}})
	base := protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "model"}},
	}
	valid := protocol.PrefixCacheModelStatus{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "direct",
		State: "ready", Reason: "ready",
	}
	validStatuses := []protocol.PrefixCacheModelStatus{valid}
	base.PrefixCacheStatuses = &validStatuses
	if err := reg.ValidatePrefixCacheRegistration(&base); err != nil {
		t.Fatalf("valid snapshot rejected: %v", err)
	}

	for _, test := range []struct {
		name   string
		mutate func(*protocol.PrefixCacheModelStatus)
	}{
		{name: "state", mutate: func(s *protocol.PrefixCacheModelStatus) { s.State = "warming" }},
		{name: "reason", mutate: func(s *protocol.PrefixCacheModelStatus) { s.Reason = "free-form" }},
		{name: "backend", mutate: func(s *protocol.PrefixCacheModelStatus) { s.Backend = "metal" }},
		{name: "strategy", mutate: func(s *protocol.PrefixCacheModelStatus) { s.ReplayStrategy = "tail" }},
		{name: "state reason mismatch", mutate: func(s *protocol.PrefixCacheModelStatus) {
			s.State = "error"
		}},
		{name: "inventory", mutate: func(s *protocol.PrefixCacheModelStatus) { s.ModelID = "other" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidate := valid
			test.mutate(&candidate)
			statuses := []protocol.PrefixCacheModelStatus{candidate}
			msg := base
			msg.PrefixCacheStatuses = &statuses
			if err := reg.ValidatePrefixCacheRegistration(&msg); err == nil {
				t.Fatal("invalid status snapshot accepted")
			}
		})
	}

	duplicates := []protocol.PrefixCacheModelStatus{valid, valid}
	msg := base
	msg.PrefixCacheStatuses = &duplicates
	if err := reg.ValidatePrefixCacheRegistration(&msg); err == nil {
		t.Fatal("duplicate status model accepted")
	}
	tooMany := make([]protocol.PrefixCacheModelStatus, maxPrefixCacheStatuses+1)
	for index := range tooMany {
		tooMany[index] = valid
		tooMany[index].ModelID = "model"
	}
	msg.PrefixCacheStatuses = &tooMany
	if err := reg.ValidatePrefixCacheRegistration(&msg); err == nil {
		t.Fatal("oversized status snapshot accepted")
	}

	offCatalog := base
	offCatalog.Models = []protocol.ModelInfo{{ID: "off-catalog"}}
	offCatalogStatuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "off-catalog", Backend: "unknown", ReplayStrategy: "none",
		State: "disabled", Reason: "config_disabled",
	}}
	offCatalog.PrefixCacheStatuses = &offCatalogStatuses
	if err := reg.ValidatePrefixCacheRegistration(&offCatalog); err == nil {
		t.Fatal("off-catalog status accepted")
	}

	badOutcome := []protocol.PrefixCacheDonationOutcomeCount{{
		Outcome: "request_specific_failure", Count: 1,
	}}
	msg = base
	msg.PrefixCacheDonationOutcomes = &badOutcome
	if err := reg.ValidatePrefixCacheRegistration(&msg); err == nil {
		t.Fatal("free-form donation outcome accepted")
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

	five := []protocol.PrefixCacheDonationOutcomeCount{{Outcome: "donated", Count: 5}}
	if err := reg.UpdatePrefixCacheTelemetry("provider", nil, &five); err != nil {
		t.Fatal(err)
	}
	if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"]; got != 3 {
		t.Fatalf("donation delta = %d, want 3", got)
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
