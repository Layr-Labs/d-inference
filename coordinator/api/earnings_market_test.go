package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func addActiveEarningsModel(
	t *testing.T,
	st store.Store,
	id, displayName string,
	minRAMGB int,
	sizeBytes int64,
) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID:          id,
		DisplayName: displayName,
		MinRAMGB:    minRAMGB,
		Status:      "active",
	}
	version := &store.ModelVersion{
		ModelID:        id,
		Version:        "v1",
		Status:         "ready",
		TotalSizeBytes: sizeBytes,
	}
	if err := st.SetModelVersion(entry, version, nil); err != nil {
		t.Fatalf("SetModelVersion(%s): %v", id, err)
	}
	if err := st.PromoteModelVersion(id, version.Version); err != nil {
		t.Fatalf("PromoteModelVersion(%s): %v", id, err)
	}
}

func registerEarningsCapacity(
	t *testing.T,
	reg *registry.Registry,
	id, model string,
	bandwidth, observedTPS float64,
	privateOnly bool,
) {
	t.Helper()
	templateOK := true
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Hardware: protocol.Hardware{
			MemoryGB:           64,
			MemoryBandwidthGBs: bandwidth,
		},
		Models: []protocol.ModelInfo{{
			ID:               model,
			ModelType:        "chat",
			TemplateRenderOK: &templateOK,
		}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivateOnly:             privateOnly,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                model,
			State:                "idle",
			MaxConcurrency:       4,
			ActiveTokenBudgetMax: 4096,
			ObservedDecodeTPS:    observedTPS,
		}},
	}
	p.Mu().Unlock()
}

func TestEarningsMarketHandlerAttributesPublicDemandAndUsesRoutedCapacity(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{})
	cfg := ServerConfig{BaseRewards: BaseRewardsConfig{
		Enabled:        true,
		ReductionK:     0.25,
		FloorPoolB:     9_000_000_000,
		MinUptimeFrac:  0.90,
		AccountCapFrac: 0.05,
	}}
	srv := NewServer(reg, st, cfg, logger)

	const (
		aliasID    = "public-model"
		desired    = "public-model-q4"
		previous   = "public-model-q8"
		retired    = "public-model-old"
		standalone = "standalone-model"
		clone      = "openrouter/clone"
	)
	addActiveEarningsModel(t, st, desired, "Desired build", 32, 20_000_000_000)
	addActiveEarningsModel(t, st, previous, "Previous build", 48, 30_000_000_000)
	addActiveEarningsModel(t, st, standalone, "Standalone", 24, 10_000_000_000)
	addActiveEarningsModel(t, st, clone, "Marketplace clone", 32, 20_000_000_000)
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID:       aliasID,
		DisplayName:   "Public Model",
		DesiredBuild:  desired,
		PreviousBuild: previous,
		RetiredBuilds: []string{retired},
		Active:        true,
	}); err != nil {
		t.Fatalf("UpsertModelAlias: %v", err)
	}
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID:        clone,
		DisplayName:    "Marketplace clone",
		OpenRouterOnly: true,
		SourceModel:    aliasID,
		SourceKind:     store.ModelAliasSourceAlias,
		DesiredBuild:   desired,
		Active:         true,
	}); err != nil {
		t.Fatalf("UpsertModelAlias clone: %v", err)
	}

	registerEarningsCapacity(t, reg, "desired-provider", desired, 400, 100, false)
	registerEarningsCapacity(t, reg, "previous-provider", previous, 200, 50, false)
	registerEarningsCapacity(t, reg, "retired-provider", retired, 800, 999, false)
	registerEarningsCapacity(t, reg, "private-provider", desired, 600, 777, true)

	now := time.Now()
	earnings := []store.ProviderEarning{
		{JobID: "desired-job", Model: desired, PublicModel: aliasID, AmountMicroUSD: 10_000_000, PromptTokens: 100, CompletionTokens: 10, CreatedAt: now},
		{JobID: "previous-job", Model: previous, PublicModel: aliasID, AmountMicroUSD: 20_000_000, PromptTokens: 200, CompletionTokens: 20, CreatedAt: now},
		{JobID: "retired-job", Model: retired, PublicModel: aliasID, AmountMicroUSD: 30_000_000, PromptTokens: 300, CompletionTokens: 30, CreatedAt: now},
		{JobID: "alias-job", Model: aliasID, PublicModel: aliasID, AmountMicroUSD: 4_000_000, PromptTokens: 40, CompletionTokens: 4, CreatedAt: now},
		{JobID: "standalone-job", Model: standalone, PublicModel: standalone, AmountMicroUSD: 5_000_000, PromptTokens: 50, CompletionTokens: 5, CreatedAt: now},
		{JobID: "unknown-job", Model: "unknown-history", AmountMicroUSD: 7_000_000, PromptTokens: 70, CompletionTokens: 7, CreatedAt: now},
		{JobID: "clone-job", Model: clone, PublicModel: clone, AmountMicroUSD: 8_000_000, PromptTokens: 80, CompletionTokens: 8, CreatedAt: now},
		{JobID: "base-job", Model: "base_reward", AmountMicroUSD: 100_000_000, CreatedAt: now},
		{JobID: "zero-job", Model: desired, PublicModel: aliasID, AmountMicroUSD: 0, PromptTokens: 999, CompletionTokens: 999, CreatedAt: now},
		{JobID: "negative-job", Model: desired, PublicModel: aliasID, AmountMicroUSD: -1, CreatedAt: now},
		{JobID: "old-job", Model: desired, PublicModel: aliasID, AmountMicroUSD: 200_000_000, CreatedAt: now.Add(-31 * 24 * time.Hour)},
	}
	for i := range earnings {
		if err := st.RecordProviderEarning(&earnings[i]); err != nil {
			t.Fatalf("RecordProviderEarning: %v", err)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/earnings/market", nil)
	req.Header.Set("Origin", "https://darkbloom.dev")
	recorder := httptest.NewRecorder()
	srv.Handler().ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want *", got)
	}

	var response earningsMarketResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.WindowDays != 30 || response.WindowEnd.Sub(response.WindowStart) != earningsMarketWindow {
		t.Fatalf("window = %d days / %s, want 30 days", response.WindowDays, response.WindowEnd.Sub(response.WindowStart))
	}
	if len(response.Models) != 2 {
		t.Fatalf("models = %+v, want alias plus standalone", response.Models)
	}
	models := make(map[string]earningsMarketModel, len(response.Models))
	for _, model := range response.Models {
		models[model.ID] = model
	}
	aliased := models[aliasID]
	if aliased.DisplayName != "Public Model" || aliased.MinRAMGB != 32 ||
		aliased.WorkPayoutMicroUSD != 64_000_000 || aliased.PaidTokens != 704 ||
		aliased.PaidJobs != 4 {
		t.Fatalf("aliased model = %+v", aliased)
	}
	if aliased.AggregateTPS != 150 || aliased.AggregateMemoryBandwidthGBs != 600 ||
		aliased.BenchmarkTPS != 150 || aliased.BenchmarkMemoryBandwidthGBs != 600 ||
		aliased.ProviderSupply != 2 || !aliased.EstimateAvailable || aliased.UnavailableReason != "" {
		t.Fatalf("aliased capacity = %+v, want desired + fallback 150 TPS / 600 GB/s / 2 providers", aliased)
	}
	standaloneModel := models[standalone]
	if standaloneModel.WorkPayoutMicroUSD != 5_000_000 || standaloneModel.PaidTokens != 55 ||
		standaloneModel.PaidJobs != 1 || standaloneModel.EstimateAvailable ||
		standaloneModel.UnavailableReason != "competing_capacity_unavailable" {
		t.Fatalf("standalone model = %+v", standaloneModel)
	}
	if _, present := models[clone]; present {
		t.Fatal("OpenRouter-only clone appeared in public earnings market")
	}

	wantAudit := earningsMarketAudit{
		TotalSettledWorkMicroUSD: 84_000_000,
		ModeledWorkMicroUSD:      69_000_000,
		UnattributedWorkMicroUSD: 15_000_000,
		TotalPaidTokens:          924,
		ModeledPaidTokens:        759,
		UnattributedPaidTokens:   165,
		TotalPaidJobs:            7,
		ModeledPaidJobs:          5,
		UnattributedPaidJobs:     2,
	}
	if response.Audit != wantAudit {
		t.Fatalf("audit = %+v, want %+v", response.Audit, wantAudit)
	}
	if !response.BaseRewards.Enabled || response.BaseRewards.MonthlyPoolMicroUSD != 9_000_000_000 ||
		response.BaseRewards.MinUptimeFraction != 0.90 || response.BaseRewards.ReductionK != 0.25 ||
		response.BaseRewards.AccountCapFraction != 0.05 || len(response.BaseRewards.Tiers) == 0 {
		t.Fatalf("base reward policy = %+v", response.BaseRewards)
	}
}

func TestBuildEarningsMarketAllowsSharedBuildWithoutCrossAttribution(t *testing.T) {
	st := store.NewMemory(store.Config{})
	const shared = "shared-build"
	addActiveEarningsModel(t, st, shared, "Shared build", 32, 20_000_000_000)
	records, err := st.ListActiveModelRegistryWithError()
	if err != nil {
		t.Fatalf("ListActiveModelRegistryWithError: %v", err)
	}
	aliases := []store.ModelAlias{
		{AliasID: "market-a", DisplayName: "Market A", DesiredBuild: shared, Active: true},
		{AliasID: "market-b", DisplayName: "Market B", PreviousBuild: shared, DesiredBuild: "inactive-build", Active: true},
	}
	work := []store.ModelSettledWorkTotal{
		{PublicModel: "market-a", WorkPayoutMicroUSD: 10_000_000, PromptTokens: 10, CompletionTokens: 5, Jobs: 1},
		{PublicModel: "market-b", WorkPayoutMicroUSD: 20_000_000, PromptTokens: 20, CompletionTokens: 10, Jobs: 2},
		{PublicModel: "", WorkPayoutMicroUSD: 30_000_000, PromptTokens: 30, CompletionTokens: 15, Jobs: 3},
	}
	start := time.Now().UTC().Add(-earningsMarketWindow)
	response, err := buildEarningsMarketResponse(
		records,
		aliases,
		[]registry.ModelCapacity{{
			ModelID:                     shared,
			EligibleProviders:           1,
			AggregateTPS:                100,
			AggregateMemoryBandwidthGBs: 400,
			BenchmarkTPS:                100,
			BenchmarkMemoryBandwidthGBs: 400,
		}},
		work,
		start,
		start.Add(earningsMarketWindow),
		BaseRewardsConfig{},
	)
	if err != nil {
		t.Fatalf("buildEarningsMarketResponse: %v", err)
	}
	if len(response.Models) != 2 {
		t.Fatalf("models = %+v, want both public markets", response.Models)
	}
	got := map[string]earningsMarketModel{}
	for _, model := range response.Models {
		got[model.ID] = model
	}
	if got["market-a"].WorkPayoutMicroUSD != 10_000_000 ||
		got["market-b"].WorkPayoutMicroUSD != 20_000_000 {
		t.Fatalf("shared-build work crossed market identities: %+v", got)
	}
	if got["market-a"].AggregateTPS != 100 || got["market-b"].AggregateTPS != 100 {
		t.Fatalf("shared-build capacity missing from a market: %+v", got)
	}
	if response.Audit.UnattributedWorkMicroUSD != 30_000_000 {
		t.Fatalf("legacy unattributed work = %d, want 30000000", response.Audit.UnattributedWorkMicroUSD)
	}
}

func TestActiveAliasMembersDeduplicatesDesiredAndFallback(t *testing.T) {
	records := map[string]store.ModelRegistryRecord{
		"shared": {ModelRegistryEntry: store.ModelRegistryEntry{ID: "shared"}},
	}
	got := activeAliasMembers(store.ModelAlias{
		DesiredBuild:  "shared",
		PreviousBuild: "shared",
	}, records)
	if len(got) != 1 || got[0] != "shared" {
		t.Fatalf("activeAliasMembers = %v, want [shared]", got)
	}
}

func TestEarningsMarketHandlerMarksMissingObservedBenchmarkUnavailable(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{})
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const modelID = "unbenchmarked-model"
	addActiveEarningsModel(t, st, modelID, "Unbenchmarked", 24, 8_000_000_000)
	registerEarningsCapacity(t, reg, "fallback-provider", modelID, 400, 0, false)
	if err := st.RecordProviderEarning(&store.ProviderEarning{
		JobID:            "unbenchmarked-job",
		Model:            modelID,
		PublicModel:      modelID,
		AmountMicroUSD:   1_000_000,
		PromptTokens:     100,
		CompletionTokens: 10,
		CreatedAt:        time.Now(),
	}); err != nil {
		t.Fatalf("RecordProviderEarning: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/earnings/market", nil)
	recorder := httptest.NewRecorder()
	srv.Handler().ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var response earningsMarketResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response.Models) != 1 {
		t.Fatalf("models = %+v, want one", response.Models)
	}
	model := response.Models[0]
	if model.AggregateTPS <= 0 || model.ProviderSupply != 1 {
		t.Fatalf("fallback capacity = %+v, want positive competing supply", model)
	}
	if model.BenchmarkTPS != 0 || model.BenchmarkMemoryBandwidthGBs != 0 ||
		model.EstimateAvailable || model.UnavailableReason != "throughput_benchmark_unavailable" {
		t.Fatalf("unbenchmarked model = %+v, want explicit throughput unavailability", model)
	}
}

type failingEarningsMarketStore struct {
	store.Store
	activeErr  error
	aliasesErr error
	workErr    error
}

func (s failingEarningsMarketStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	if s.activeErr != nil {
		return nil, s.activeErr
	}
	return s.Store.ListActiveModelRegistryWithError()
}

func (s failingEarningsMarketStore) ListModelAliases() ([]store.ModelAlias, error) {
	if s.aliasesErr != nil {
		return nil, s.aliasesErr
	}
	return s.Store.ListModelAliases()
}

func (s failingEarningsMarketStore) ModelSettledWorkTotals(since, until time.Time) ([]store.ModelSettledWorkTotal, error) {
	if s.workErr != nil {
		return nil, s.workErr
	}
	return s.Store.ModelSettledWorkTotals(since, until)
}

func TestEarningsMarketHandlerReturns500OnStoreFailures(t *testing.T) {
	tests := map[string]failingEarningsMarketStore{
		"catalog": {activeErr: errors.New("catalog failed")},
		"aliases": {aliasesErr: errors.New("aliases failed")},
		"work":    {workErr: errors.New("work failed")},
	}
	for name, failure := range tests {
		t.Run(name, func(t *testing.T) {
			base := store.NewMemory(store.Config{})
			failure.Store = base
			srv := NewServer(registry.New(quietLogger()), failure, ServerConfig{}, quietLogger())
			req := httptest.NewRequest(http.MethodGet, "/v1/earnings/market", nil)
			recorder := httptest.NewRecorder()
			srv.Handler().ServeHTTP(recorder, req)
			if recorder.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want 500; body = %s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestEarningsMarketHandlerReturns500OnInvalidCatalogMetadata(t *testing.T) {
	st := store.NewMemory(store.Config{})
	addActiveEarningsModel(t, st, "invalid-model", "Invalid", 0, 1_000_000)
	srv := NewServer(registry.New(quietLogger()), st, ServerConfig{}, quietLogger())
	req := httptest.NewRequest(http.MethodGet, "/v1/earnings/market", nil)
	recorder := httptest.NewRecorder()
	srv.Handler().ServeHTTP(recorder, req)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500; body = %s", recorder.Code, recorder.Body.String())
	}
}
