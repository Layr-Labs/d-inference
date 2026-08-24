package api

import (
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
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
	registerEarningsCapacity(t, reg, "previous-provider", previous, 100, 50, false)
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
		aliased.WorkPayoutMicroUSD != 72_000_000 || aliased.PaidTokens != 792 ||
		aliased.PaidJobs != 5 {
		t.Fatalf("aliased model = %+v", aliased)
	}
	if aliased.AggregateTPS != 100 || aliased.AggregateMemoryBandwidthGBs != 400 ||
		aliased.BenchmarkTPS != 100 || aliased.BenchmarkMemoryBandwidthGBs != 400 ||
		aliased.ProviderSupply != 1 || !aliased.EstimateAvailable || aliased.UnavailableReason != "" {
		t.Fatalf("aliased capacity = %+v, want desired build only at 100 TPS / 400 GB/s / 1 provider", aliased)
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
		ModeledWorkMicroUSD:      77_000_000,
		UnattributedWorkMicroUSD: 7_000_000,
		TotalPaidTokens:          924,
		ModeledPaidTokens:        847,
		UnattributedPaidTokens:   77,
		TotalPaidJobs:            7,
		ModeledPaidJobs:          6,
		UnattributedPaidJobs:     1,
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
			ObservedBenchmarkProviders:  1,
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

func TestActiveAliasTargetsPreferDesiredWithPreviousFallback(t *testing.T) {
	records := map[string]store.ModelRegistryRecord{
		"desired": {ModelRegistryEntry: store.ModelRegistryEntry{ID: "desired"}},
		"shared":  {ModelRegistryEntry: store.ModelRegistryEntry{ID: "shared"}},
	}
	candidate, fallback, ok := activeAliasTargets(store.ModelAlias{
		DesiredBuild:  "desired",
		PreviousBuild: "shared",
	}, records)
	if !ok || candidate != "desired" || fallback != "shared" {
		t.Fatalf(
			"activeAliasTargets = %q/%q/%t, want desired/shared/true",
			candidate,
			fallback,
			ok,
		)
	}
	delete(records, "desired")
	candidate, fallback, ok = activeAliasTargets(store.ModelAlias{
		DesiredBuild:  "desired",
		PreviousBuild: "shared",
	}, records)
	if !ok || candidate != "shared" || fallback != "" {
		t.Fatalf(
			"activeAliasTargets previous-only = %q/%q/%t, want shared/empty/true",
			candidate,
			fallback,
			ok,
		)
	}
}

func TestBuildEarningsMarketUsesRoutablePreviousCapacityWithoutBorrowingItsBenchmark(t *testing.T) {
	st := store.NewMemory(store.Config{})
	const (
		aliasID  = "rollout-market"
		desired  = "rollout-desired"
		previous = "rollout-previous"
	)
	addActiveEarningsModel(t, st, desired, "Desired", 32, 20_000_000_000)
	addActiveEarningsModel(t, st, previous, "Previous", 32, 20_000_000_000)
	records, err := st.ListActiveModelRegistryWithError()
	if err != nil {
		t.Fatalf("ListActiveModelRegistryWithError: %v", err)
	}
	start := time.Now().UTC().Add(-earningsMarketWindow)
	response, err := buildEarningsMarketResponse(
		records,
		[]store.ModelAlias{{
			AliasID: aliasID, DesiredBuild: desired, PreviousBuild: previous, Active: true,
		}},
		[]registry.ModelCapacity{{
			ModelID:                     previous,
			EligibleProviders:           1,
			AggregateTPS:                999,
			AggregateMemoryBandwidthGBs: 400,
			BenchmarkTPS:                100,
			BenchmarkMemoryBandwidthGBs: 400,
			ObservedBenchmarkProviders:  1,
		}},
		[]store.ModelSettledWorkTotal{{
			PublicModel: aliasID, WorkPayoutMicroUSD: 1_000_000,
			PromptTokens: 100, CompletionTokens: 10, Jobs: 1,
		}},
		start,
		start.Add(earningsMarketWindow),
		BaseRewardsConfig{},
	)
	if err != nil {
		t.Fatalf("buildEarningsMarketResponse: %v", err)
	}
	if len(response.Models) != 1 {
		t.Fatalf("models = %+v, want one", response.Models)
	}
	model := response.Models[0]
	if model.AggregateTPS != 100 || model.AggregateMemoryBandwidthGBs != 400 ||
		model.ProviderSupply != 1 {
		t.Fatalf("routed previous capacity = %+v, want measured 100 TPS / 400 GB/s", model)
	}
	if model.BenchmarkTPS != 0 || model.BenchmarkMemoryBandwidthGBs != 0 ||
		model.EstimateAvailable || model.UnavailableReason != "throughput_benchmark_unavailable" {
		t.Fatalf("desired candidate benchmark = %+v, want explicit unavailability", model)
	}
}

func TestEarningsMarketHandlerMarksUnobservedCompetingCapacityUnavailable(t *testing.T) {
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
	if model.AggregateTPS != 0 || model.AggregateMemoryBandwidthGBs != 0 ||
		model.ProviderSupply != 1 {
		t.Fatalf("unobserved competing capacity = %+v, want zero measured capacity and one provider", model)
	}
	if model.BenchmarkTPS != 0 || model.BenchmarkMemoryBandwidthGBs != 0 ||
		model.EstimateAvailable || model.UnavailableReason != "competing_capacity_unavailable" {
		t.Fatalf("unobserved model = %+v, want explicit competing-capacity unavailability", model)
	}
}

func TestEarningsMarketHandlerRejectsPartialObservedCapacity(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{})
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const modelID = "partially-benchmarked-model"
	addActiveEarningsModel(t, st, modelID, "Partial benchmark", 24, 8_000_000_000)
	registerEarningsCapacity(t, reg, "observed-provider", modelID, 400, 100, false)
	registerEarningsCapacity(t, reg, "unobserved-provider", modelID, 200, 0, false)
	if err := st.RecordProviderEarning(&store.ProviderEarning{
		JobID:            "partial-benchmark-job",
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
	if model.ProviderSupply != 2 || model.AggregateTPS != 0 || model.BenchmarkTPS != 0 ||
		model.EstimateAvailable || model.UnavailableReason != "competing_capacity_unavailable" {
		t.Fatalf("partial observed capacity = %+v, want explicit unavailability", model)
	}
}

type failingEarningsMarketStore struct {
	store.Store
	activeErr  error
	aliasesErr error
	workErr    error
}

type countingEarningsMarketStore struct {
	store.Store
	workCalls atomic.Int32
	delay     time.Duration
	workErr   error
}

func (s *countingEarningsMarketStore) ModelSettledWorkTotals(since, until time.Time) ([]store.ModelSettledWorkTotal, error) {
	s.workCalls.Add(1)
	time.Sleep(s.delay)
	if s.workErr != nil {
		return nil, s.workErr
	}
	return s.Store.ModelSettledWorkTotals(since, until)
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

func TestEarningsMarketHandlerCoalescesConcurrentCacheMisses(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	base := store.NewMemory(store.Config{})
	const modelID = "coalesced-market-model"
	addActiveEarningsModel(t, base, modelID, "Coalesced", 24, 8_000_000_000)
	registerEarningsCapacity(t, reg, "coalesced-provider", modelID, 400, 100, false)
	if err := base.RecordProviderEarning(&store.ProviderEarning{
		JobID:            "coalesced-job",
		Model:            modelID,
		PublicModel:      modelID,
		AmountMicroUSD:   1_000_000,
		PromptTokens:     100,
		CompletionTokens: 10,
		CreatedAt:        time.Now(),
	}); err != nil {
		t.Fatalf("RecordProviderEarning: %v", err)
	}
	counting := &countingEarningsMarketStore{
		Store: base,
		delay: 50 * time.Millisecond,
	}
	srv := NewServer(reg, counting, ServerConfig{}, logger)

	const requestCount = 16
	statuses := runConcurrentEarningsRequests(t, srv, requestCount)
	for _, status := range statuses {
		if status != http.StatusOK {
			t.Fatalf("status = %d, want 200", status)
		}
	}
	if calls := counting.workCalls.Load(); calls != 1 {
		t.Fatalf("settled-work queries = %d, want 1 for one concurrent cache miss", calls)
	}
}

func TestEarningsMarketHandlerCoalescesConcurrentFailures(t *testing.T) {
	counting := &countingEarningsMarketStore{
		Store:   store.NewMemory(store.Config{}),
		delay:   50 * time.Millisecond,
		workErr: errors.New("database unavailable"),
	}
	srv := NewServer(registry.New(quietLogger()), counting, ServerConfig{}, quietLogger())

	const requestCount = 16
	statuses := runConcurrentEarningsRequests(t, srv, requestCount)
	for _, status := range statuses {
		if status != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", status)
		}
	}
	if calls := counting.workCalls.Load(); calls != 1 {
		t.Fatalf("failed settled-work queries = %d, want one shared failure", calls)
	}

	srv.earningsMarketMu.Lock()
	srv.earningsMarketFailureUntil = time.Time{}
	srv.earningsMarketMu.Unlock()
	req := httptest.NewRequest(http.MethodGet, "/v1/earnings/market", nil)
	recorder := httptest.NewRecorder()
	srv.Handler().ServeHTTP(recorder, req)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("retry status = %d, want 500", recorder.Code)
	}
	if calls := counting.workCalls.Load(); calls != 2 {
		t.Fatalf("queries after retry boundary = %d, want 2", calls)
	}
}

func runConcurrentEarningsRequests(t *testing.T, srv *Server, requestCount int) []int {
	t.Helper()
	start := make(chan struct{})
	statuses := make(chan int, requestCount)
	var wg sync.WaitGroup
	for range requestCount {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			req := httptest.NewRequest(http.MethodGet, "/v1/earnings/market", nil)
			recorder := httptest.NewRecorder()
			srv.Handler().ServeHTTP(recorder, req)
			statuses <- recorder.Code
		}()
	}
	close(start)
	wg.Wait()
	close(statuses)

	out := make([]int, 0, requestCount)
	for status := range statuses {
		out = append(out, status)
	}
	return out
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

func TestValidateEarningsWorkTotalRejectsMalformedUsage(t *testing.T) {
	valid := store.ModelSettledWorkTotal{
		PublicModel:        "model",
		WorkPayoutMicroUSD: 1,
		PromptTokens:       1,
		CompletionTokens:   1,
		Jobs:               1,
	}
	if err := validateEarningsWorkTotal(valid); err != nil {
		t.Fatalf("valid total rejected: %v", err)
	}
	for name, mutate := range map[string]func(*store.ModelSettledWorkTotal){
		"nonpositive payout": func(total *store.ModelSettledWorkTotal) {
			total.WorkPayoutMicroUSD = 0
		},
		"negative prompt tokens": func(total *store.ModelSettledWorkTotal) {
			total.PromptTokens = -1
		},
		"negative completion tokens": func(total *store.ModelSettledWorkTotal) {
			total.CompletionTokens = -1
		},
		"nonpositive jobs": func(total *store.ModelSettledWorkTotal) {
			total.Jobs = 0
		},
		"token overflow": func(total *store.ModelSettledWorkTotal) {
			total.PromptTokens = math.MaxInt64
			total.CompletionTokens = 1
		},
	} {
		t.Run(name, func(t *testing.T) {
			total := valid
			mutate(&total)
			if err := validateEarningsWorkTotal(total); err == nil {
				t.Fatalf("invalid total accepted: %+v", total)
			}
		})
	}
}
