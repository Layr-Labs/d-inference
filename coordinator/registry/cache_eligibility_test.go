package registry

import (
	"fmt"
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
			want: "ready,config_disabled,weight_hash_unavailable," +
				"runtime_identity_unavailable,unsupported_layout,unsupported_backend," +
				"paged_hybrid_unsupported,scan_pending,scan_failed,disk_unavailable,cache_init_failed",
		},
		"backends": {
			got: PrefixCacheStatusBackends(), want: "contiguous,paged,unknown",
		},
		"strategies": {
			got:  PrefixCacheReplayStrategies(),
			want: "direct,frozen_full,tail_replay,none,unknown",
		},
		"init failure details": {
			got: PrefixCacheInitFailureDetails(),
			want: "key_unavailable,ephemeral_key_unavailable,block_contract_mismatch," +
				"epoch_unavailable,prompt_contract_unavailable,template_artifact_missing," +
				"template_dynamic_date,template_render_failed,epoch_lost,cache_closed,unknown",
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

func TestDonationOutcomeForwardVersionHeadroomPreservesKnownCounters(t *testing.T) {
	knownOutcomes := PrefixCacheDonationOutcomes()
	if len(knownOutcomes) != 13 {
		t.Fatalf("known outcome buckets=%d, want 13", len(knownOutcomes))
	}
	knownCounters := func(offset uint64) []protocol.PrefixCacheDonationOutcomeCount {
		result := make(
			[]protocol.PrefixCacheDonationOutcomeCount,
			0,
			len(knownOutcomes),
		)
		for index, outcome := range knownOutcomes {
			result = append(result, protocol.PrefixCacheDonationOutcomeCount{
				Outcome: outcome,
				Count:   uint64(index+1) + offset,
			})
		}
		return result
	}
	withFuture := func(
		known []protocol.PrefixCacheDonationOutcomeCount,
		futureCount int,
	) []protocol.PrefixCacheDonationOutcomeCount {
		result := append([]protocol.PrefixCacheDonationOutcomeCount(nil), known...)
		for index := range futureCount {
			result = append(result, protocol.PrefixCacheDonationOutcomeCount{
				Outcome: fmt.Sprintf("future_outcome_%d", index),
				Count:   uint64(index + 1),
			})
		}
		return result
	}

	reg := cacheEligibilityTestRegistry()
	allKnownPlusOneFuture := withFuture(knownCounters(0), 1)
	registration := protocol.RegisterMessage{
		Models:                      []protocol.ModelInfo{{ID: "model"}},
		PrefixCacheDonationOutcomes: &allKnownPlusOneFuture,
	}
	if err := reg.ValidatePrefixCacheRegistration(&registration); err != nil {
		t.Fatalf("known+future registration became fatal: %v", err)
	}
	if got := len(*registration.PrefixCacheDonationOutcomes); got != len(knownOutcomes) {
		t.Fatalf("known+future sanitized entries=%d, want %d", got, len(knownOutcomes))
	}

	atCap := withFuture(
		knownCounters(0),
		maxPrefixCacheDonationOutcomeEntries-len(knownOutcomes),
	)
	atCapRegistration := protocol.RegisterMessage{
		Models:                      []protocol.ModelInfo{{ID: "model"}},
		PrefixCacheDonationOutcomes: &atCap,
	}
	if err := reg.ValidatePrefixCacheRegistration(&atCapRegistration); err != nil {
		t.Fatalf("at-cap registration became fatal: %v", err)
	}
	if got := len(*atCapRegistration.PrefixCacheDonationOutcomes); got != len(knownOutcomes) {
		t.Fatalf("at-cap sanitized entries=%d, want %d", got, len(knownOutcomes))
	}

	overCap := append(
		withFuture(
			knownCounters(0),
			maxPrefixCacheDonationOutcomeEntries-len(knownOutcomes),
		),
		protocol.PrefixCacheDonationOutcomeCount{
			Outcome: "future_outcome_over_cap", Count: 1,
		},
	)
	overCapRegistration := protocol.RegisterMessage{
		Models:                      []protocol.ModelInfo{{ID: "model"}},
		PrefixCacheDonationOutcomes: &overCap,
	}
	if err := reg.ValidatePrefixCacheRegistration(&overCapRegistration); err != nil {
		t.Fatalf("over-cap optional telemetry became fatal: %v", err)
	}
	if got := len(*overCapRegistration.PrefixCacheDonationOutcomes); got != 0 {
		t.Fatalf("over-cap snapshot retained %d entries, want 0", got)
	}

	baseline := knownCounters(0)
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{
		Models:                      []protocol.ModelInfo{{ID: "model"}},
		PrefixCacheDonationOutcomes: &baseline,
	})
	updated := withFuture(knownCounters(10), 1)
	if err := reg.UpdatePrefixCacheTelemetry(provider.ID, nil, &updated); err != nil {
		t.Fatal(err)
	}
	for _, outcome := range knownOutcomes {
		if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes[outcome]; got != 10 {
			t.Fatalf("%s delta=%d, want 10", outcome, got)
		}
	}

	overCapHeartbeat := append(
		withFuture(
			knownCounters(20),
			maxPrefixCacheDonationOutcomeEntries-len(knownOutcomes),
		),
		protocol.PrefixCacheDonationOutcomeCount{
			Outcome: "future_outcome_over_cap", Count: 1,
		},
	)
	if err := reg.UpdatePrefixCacheTelemetry(
		provider.ID, nil, &overCapHeartbeat); err != nil {
		t.Fatalf("over-cap heartbeat became fatal: %v", err)
	}
	for _, outcome := range knownOutcomes {
		if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes[outcome]; got != 10 {
			t.Fatalf("%s changed after over-cap snapshot: %d", outcome, got)
		}
	}

	recovered := withFuture(knownCounters(30), 1)
	if err := reg.UpdatePrefixCacheTelemetry(provider.ID, nil, &recovered); err != nil {
		t.Fatal(err)
	}
	for _, outcome := range knownOutcomes {
		if got := reg.CacheRoutingLifecycleStatus().DonationOutcomes[outcome]; got != 30 {
			t.Fatalf("%s recovered total=%d, want 30", outcome, got)
		}
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

func TestPrefixCacheInitFailureDetailSanitizationKeepsEntries(t *testing.T) {
	// The granular detail is diagnostic-only: it is normalized (possibly to
	// "") but NEVER costs the entry or the snapshot, in either direction of
	// version skew.
	for name, test := range map[string]struct {
		status protocol.PrefixCacheModelStatus
		want   string
	}{
		"valid detail preserved": {
			status: protocol.PrefixCacheModelStatus{
				ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
				State: "error", Reason: "cache_init_failed",
				InitFailure: "key_unavailable",
			},
			want: "key_unavailable",
		},
		"discriminated template detail preserved": {
			status: protocol.PrefixCacheModelStatus{
				ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
				State: "error", Reason: "cache_init_failed",
				InitFailure: "template_artifact_missing",
			},
			want: "template_artifact_missing",
		},
		"unknown future detail stripped entry kept": {
			status: protocol.PrefixCacheModelStatus{
				ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
				State: "error", Reason: "cache_init_failed",
				InitFailure: "future_detail",
			},
			want: "",
		},
		"detail under mismatched reason stripped entry kept": {
			status: protocol.PrefixCacheModelStatus{
				ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
				State: "disabled", Reason: "config_disabled",
				InitFailure: "key_unavailable",
			},
			want: "",
		},
		"old provider empty detail preserved": {
			status: protocol.PrefixCacheModelStatus{
				ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
				State: "error", Reason: "cache_init_failed",
			},
			want: "",
		},
	} {
		t.Run(name, func(t *testing.T) {
			statuses := []protocol.PrefixCacheModelStatus{test.status}
			msg := protocol.RegisterMessage{
				Models:              []protocol.ModelInfo{{ID: "model"}},
				PrefixCacheStatuses: &statuses,
			}
			reg := cacheEligibilityTestRegistry()
			if err := reg.ValidatePrefixCacheRegistration(&msg); err != nil {
				t.Fatalf("optional detail closed registration: %v", err)
			}
			if msg.PrefixCacheStatuses == nil || len(*msg.PrefixCacheStatuses) != 1 {
				t.Fatalf("detail sanitization dropped the entry: %+v", msg.PrefixCacheStatuses)
			}
			got := (*msg.PrefixCacheStatuses)[0]
			if got.InitFailure != test.want {
				t.Fatalf("init failure=%q, want %q", got.InitFailure, test.want)
			}
			if got.State != test.status.State || got.Reason != test.status.Reason {
				t.Fatalf("state/reason changed by detail sanitization: %+v", got)
			}
		})
	}
}

func TestPrefixCacheInitFailureAggregationBreakdown(t *testing.T) {
	reg := cacheEligibilityTestRegistry()
	statuses := []protocol.PrefixCacheModelStatus{
		{
			ModelID: "key-lost", Backend: "contiguous", ReplayStrategy: "none",
			State: "error", Reason: "cache_init_failed",
			InitFailure: "key_unavailable",
		},
		{
			ModelID: "epoch-lost", Backend: "paged", ReplayStrategy: "none",
			State: "error", Reason: "cache_init_failed",
			InitFailure: "epoch_lost",
		},
		{
			ModelID: "old-provider", Backend: "contiguous", ReplayStrategy: "none",
			State: "error", Reason: "cache_init_failed",
		},
		{
			ModelID: "gpt-oss-dynamic", Backend: "contiguous", ReplayStrategy: "none",
			State: "error", Reason: "cache_init_failed",
			InitFailure: "template_dynamic_date",
		},
		{
			ModelID: "healthy", Backend: "contiguous", ReplayStrategy: "unknown",
			State: "pending", Reason: "scan_pending",
		},
	}
	msg := protocol.RegisterMessage{
		Models: []protocol.ModelInfo{
			{ID: "key-lost"}, {ID: "epoch-lost"}, {ID: "old-provider"},
			{ID: "gpt-oss-dynamic"}, {ID: "healthy"},
		},
		PrefixCacheStatuses: &statuses,
	}
	if err := reg.ValidatePrefixCacheRegistration(&msg); err != nil {
		t.Fatal(err)
	}
	if reg.Register("provider", nil, &msg) == nil {
		t.Fatal("provider did not register")
	}

	aggregate := reg.PrefixCacheProtocolStatus()
	// The plain reason total keeps its meaning: detail-less entries from old
	// providers still count, so the detail buckets sum to at most the total.
	if aggregate.ByReason["cache_init_failed"] != 4 {
		t.Fatalf("cache_init_failed total=%d, want 4", aggregate.ByReason["cache_init_failed"])
	}
	if aggregate.ByInitFailure["key_unavailable"] != 1 ||
		aggregate.ByInitFailure["epoch_lost"] != 1 ||
		aggregate.ByInitFailure["template_dynamic_date"] != 1 {
		t.Fatalf("detail breakdown=%+v", aggregate.ByInitFailure)
	}
	detailTotal := 0
	for _, count := range aggregate.ByInitFailure {
		detailTotal += count
	}
	if detailTotal != 3 {
		t.Fatalf("detail bucket sum=%d, want 3 (old provider has no detail)", detailTotal)
	}
	for _, detail := range PrefixCacheInitFailureDetails() {
		if _, ok := aggregate.ByInitFailure[detail]; !ok {
			t.Fatalf("missing zero bucket for %q: %+v", detail, aggregate.ByInitFailure)
		}
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
			name: "oversized",
			outcomes: make(
				[]protocol.PrefixCacheDonationOutcomeCount,
				maxPrefixCacheDonationOutcomeEntries+1,
			),
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

func TestPrefixCacheReadyStatusCapabilityReconciliation(t *testing.T) {
	const epoch = "11111111-1111-1111-1111-111111111111"
	capability := testV2Capability(epoch)
	model := protocol.ModelInfo{
		ID: capability.ModelID, WeightHash: capability.ModelAggregateHash,
	}
	ready := protocol.PrefixCacheModelStatus{
		ModelID: capability.ModelID, Backend: "contiguous", ReplayStrategy: "direct",
		State: "ready", Reason: "ready",
	}

	for _, test := range []struct {
		name         string
		version      int
		capabilities []protocol.PrefixCacheV2Capability
		statuses     []protocol.PrefixCacheModelStatus
		wantReported bool
		wantCount    int
	}{
		{
			name:    "protocol one ready is dropped",
			version: 1, statuses: []protocol.PrefixCacheModelStatus{ready},
			wantReported: true,
		},
		{
			name:    "ready unknown backend makes v2 status unreported",
			version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability},
			statuses: []protocol.PrefixCacheModelStatus{{
				ModelID: capability.ModelID, Backend: "unknown", ReplayStrategy: "direct",
				State: "ready", Reason: "ready",
			}},
		},
		{
			name:    "ready none strategy makes v2 status unreported",
			version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability},
			statuses: []protocol.PrefixCacheModelStatus{{
				ModelID: capability.ModelID, Backend: "paged", ReplayStrategy: "none",
				State: "ready", Reason: "ready",
			}},
		},
		{
			name:    "ready unknown strategy makes v2 status unreported",
			version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability},
			statuses: []protocol.PrefixCacheModelStatus{{
				ModelID: capability.ModelID, Backend: "paged", ReplayStrategy: "unknown",
				State: "ready", Reason: "ready",
			}},
		},
		{
			name:    "v2 capability missing ready status becomes unreported",
			version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability},
			statuses: []protocol.PrefixCacheModelStatus{{
				ModelID: capability.ModelID, Backend: "paged", ReplayStrategy: "tail_replay",
				State: "pending", Reason: "scan_pending",
			}},
		},
		{
			name:    "concrete matching ready status remains reported",
			version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability},
			statuses: []protocol.PrefixCacheModelStatus{{
				ModelID: capability.ModelID, Backend: "paged", ReplayStrategy: "tail_replay",
				State: "ready", Reason: "ready",
			}},
			wantReported: true, wantCount: 1,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			statuses := append([]protocol.PrefixCacheModelStatus(nil), test.statuses...)
			msg := protocol.RegisterMessage{
				Models:              []protocol.ModelInfo{model},
				PrefixCacheProtocol: test.version,
				PrefixCacheV2Models: test.capabilities,
				PrefixCacheStatuses: &statuses,
			}
			if err := cacheEligibilityTestRegistry().
				ValidatePrefixCacheRegistration(&msg); err != nil {
				t.Fatal(err)
			}
			reported := msg.PrefixCacheStatuses != nil
			if reported != test.wantReported {
				t.Fatalf("reported=%v, want %v; statuses=%+v",
					reported, test.wantReported, msg.PrefixCacheStatuses)
			}
			if reported && len(*msg.PrefixCacheStatuses) != test.wantCount {
				t.Fatalf("status count=%d, want %d", len(*msg.PrefixCacheStatuses), test.wantCount)
			}
		})
	}

	// Off-catalog owner-local models remain valid when provider inventory,
	// capability, and concrete ready status agree.
	reg := cacheEligibilityTestRegistry()
	reg.SetModelCatalog([]CatalogEntry{{ID: "public-model"}})
	ownerCapability := capability
	ownerCapability.ModelID = "owner-local"
	ownerStatus := ready
	ownerStatus.ModelID = ownerCapability.ModelID
	ownerStatuses := []protocol.PrefixCacheModelStatus{ownerStatus}
	owner := protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{
			ID: ownerCapability.ModelID, WeightHash: ownerCapability.ModelAggregateHash,
		}},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{ownerCapability},
		PrefixCacheStatuses: &ownerStatuses,
	}
	if err := reg.ValidatePrefixCacheRegistration(&owner); err != nil {
		t.Fatalf("matching owner-local ready status rejected: %v", err)
	}
	provider := reg.Register("owner", nil, &owner)
	if provider == nil {
		t.Fatal("owner-local provider did not register")
	}
	aggregate := reg.PrefixCacheProtocolStatus()
	if aggregate.V2ReadyModels != 1 || aggregate.ByState["ready"] != 1 {
		t.Fatalf("owner-local ready aggregate=%+v", aggregate)
	}

	// Old-provider omission never invalidates a strict valid capability.
	omitted := protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{model},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	}
	if err := reg.ValidatePrefixCacheRegistration(&omitted); err != nil {
		t.Fatal(err)
	}
	if omitted.PrefixCacheStatuses != nil {
		t.Fatal("old-provider omission was converted to a status snapshot")
	}
}

func TestPrefixCacheHeartbeatSnapshotReconcilesAtomically(t *testing.T) {
	const epoch = "11111111-1111-1111-1111-111111111111"
	capability := testV2Capability(epoch)
	ready := protocol.PrefixCacheModelStatus{
		ModelID: capability.ModelID, Backend: "contiguous", ReplayStrategy: "direct",
		State: "ready", Reason: "ready",
	}
	statuses := []protocol.PrefixCacheModelStatus{ready}
	reg := cacheEligibilityTestRegistry()
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{
			ID: capability.ModelID, WeightHash: capability.ModelAggregateHash,
		}},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
		PrefixCacheStatuses: &statuses,
	})

	pending := []protocol.PrefixCacheModelStatus{{
		ModelID: capability.ModelID, Backend: "contiguous", ReplayStrategy: "direct",
		State: "pending", Reason: "scan_pending",
	}}
	if _, err := reg.UpdatePrefixCacheSnapshot(
		provider.ID, false, 0, nil, &pending, nil); err != nil {
		t.Fatal(err)
	}
	provider.mu.Lock()
	if !provider.PrefixCacheV2Models[capability.ModelID].Ready ||
		provider.PrefixCacheStatusReported ||
		len(provider.PrefixCacheStatuses) != 0 {
		t.Fatalf("capability/status contradiction leaked after replacement: %+v", provider)
	}
	provider.mu.Unlock()

	restored := []protocol.PrefixCacheModelStatus{ready}
	if _, err := reg.UpdatePrefixCacheSnapshot(
		provider.ID, false, 0, nil, &restored, nil); err != nil {
		t.Fatal(err)
	}
	provider.mu.Lock()
	if !provider.PrefixCacheStatusReported ||
		provider.PrefixCacheStatuses[capability.ModelID].State != "ready" {
		t.Fatalf("matching status did not restore: %+v", provider.PrefixCacheStatuses)
	}
	provider.mu.Unlock()

	readyOnV1 := []protocol.PrefixCacheModelStatus{ready}
	if _, err := reg.UpdatePrefixCacheSnapshot(
		provider.ID, true, 1, nil, &readyOnV1, nil); err != nil {
		t.Fatal(err)
	}
	provider.mu.Lock()
	if provider.PrefixCacheProtocol != 1 ||
		len(provider.PrefixCacheV2Models) != 0 ||
		!provider.PrefixCacheStatusReported ||
		len(provider.PrefixCacheStatuses) != 0 {
		t.Fatalf("protocol-v1 ready telemetry was not atomically dropped: %+v", provider)
	}
	provider.mu.Unlock()
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
	if got.LoadedModels != 4 || got.ReportedLoadedModels != 2 ||
		got.UnreportedLoadedModels != 2 || got.ExcludedModels != 2 ||
		got.ByState["ready"] != 0 ||
		got.ByReason["scan_pending"] != 1 ||
		got.ByReason["weight_hash_unavailable"] != 1 ||
		got.ByBackend["contiguous"] != 1 ||
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

	replacement := []protocol.PrefixCacheModelStatus{statuses[1]}
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
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	capability.ModelID = "old"
	baseline := []protocol.PrefixCacheDonationOutcomeCount{{
		Outcome: "donated", Count: 2,
	}}
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{
			ID: "old", WeightHash: capability.ModelAggregateHash,
		}},
		PrefixCacheProtocol:         2,
		PrefixCacheV2Models:         []protocol.PrefixCacheV2Capability{capability},
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
		maxPrefixCacheDonationOutcomeEntries+1,
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
