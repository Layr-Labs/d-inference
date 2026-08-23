package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)


func TestProductionInventoryCoversFourModelsAndEverySupportedVector(t *testing.T) {
	inventory, err := readProductionInventory(filepath.Join(
		"..", "..", "..", "fixtures", "prompt-contract", "v1", "production_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if inventory.Models != 4 || inventory.EligibleModels != 3 {
		t.Fatalf("model inventory = %+v", inventory)
	}
	if len(inventory.Contracts) != 3 {
		t.Fatalf("deduplicated contracts = %d, want 3", len(inventory.Contracts))
	}
	expectedCaseIDs := namedProductionCaseIDs(t)
	expectedCases := make(map[string]struct{}, len(expectedCaseIDs))
	for _, caseID := range expectedCaseIDs {
		expectedCases[caseID] = struct{}{}
	}
	wantVectors := inventory.EligibleModels * len(expectedCases)
	if len(inventory.Vectors) != wantVectors {
		t.Fatalf("supported vectors = %d, want %d named cases across %d models",
			len(inventory.Vectors), len(expectedCases), inventory.EligibleModels)
	}
	coveredModels := make(map[string]map[string]struct{})
	for _, vector := range inventory.Vectors {
		modelID, caseID, ok := strings.Cut(vector.Name, "/")
		if !ok || modelID != vector.ModelID {
			t.Fatalf("vector name %q does not bind model %q", vector.Name, vector.ModelID)
		}
		if _, ok := expectedCases[caseID]; !ok {
			t.Fatalf("unexpected production case %q", caseID)
		}
		if coveredModels[modelID] == nil {
			coveredModels[modelID] = make(map[string]struct{}, len(expectedCases))
		}
		coveredModels[modelID][caseID] = struct{}{}
	}
	if len(coveredModels) != inventory.EligibleModels {
		t.Fatalf("covered routable models = %d, want %d", len(coveredModels), inventory.EligibleModels)
	}
	for modelID, cases := range coveredModels {
		if len(cases) != len(expectedCases) {
			t.Fatalf("model %q covers %d named cases, want %d", modelID, len(cases), len(expectedCases))
		}
		for caseID := range expectedCases {
			if _, ok := cases[caseID]; !ok {
				t.Fatalf("model %q is missing production case %q", modelID, caseID)
			}
		}
	}
}

func TestProductionInventoryRejectsIncompleteModelSet(t *testing.T) {
	_, err := validateProductionCorpus(productionCorpus{SchemaVersion: productionCorpusSchema})
	if err == nil {
		t.Fatal("incomplete production inventory was accepted")
	}
}

func TestRunProductionLoadChecksEveryPlan(t *testing.T) {
	contractID := "a7b12f689310098261b1aeb0d65d01c3e535d4f0822e84b2bf37c9e9b5d0f4ab"
	expected := promptcontract.Plan{
		PromptContractID: contractID,
		PromptTokenCount: 31,
	}
	client := staticPlanClient{plan: promptcontract.Plan{
		Participating:    true,
		PromptContractID: contractID,
		PromptTokenCount: 31,
	}}
	report, err := runProductionLoad(context.Background(), client, []planVector{{
		Name:             "model/case",
		PromptContractID: contractID,
		ScopeID:          "scope",
		ProviderBody:     []byte(`{"model":"model","messages":[]}`),
		Expected:         expected,
	}}, loadConfig{
		QPS:            1_000,
		Duration:       2 * time.Millisecond,
		RequestTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	if report.Requests != 2 || report.Succeeded != 2 || report.Errors != 0 ||
		report.Mismatches != 0 || report.CoveredVectors != 1 {
		t.Fatalf("load report = %+v", report)
	}
}

func TestRunProductionLoadRejectsUnboundedRate(t *testing.T) {
	_, err := runProductionLoad(
		context.Background(), staticPlanClient{}, []planVector{{Name: "vector"}},
		loadConfig{QPS: maxLoadQPS + 1, Duration: time.Second, RequestTimeout: time.Second},
	)
	if err == nil {
		t.Fatal("unbounded load rate was accepted")
	}
}

func TestPlanDifferenceRejectsNonParticipatingAndMismatchedPlans(t *testing.T) {
	expected := promptcontract.Plan{
		PromptContractID: "a7b12f689310098261b1aeb0d65d01c3e535d4f0822e84b2bf37c9e9b5d0f4ab",
		PromptTokenCount: 9,
	}
	if difference := planDifference(expected, expected); difference != "plan did not participate" {
		t.Fatalf("non-participating difference = %q", difference)
	}
	actual := expected
	actual.Participating = true
	if difference := planDifference(expected, actual); difference != "" {
		t.Fatalf("matching plan difference = %q", difference)
	}
	actual.PromptTokenCount++
	if difference := planDifference(expected, actual); difference == "" {
		t.Fatal("mismatched plan was accepted")
	}
}

func TestValidateSummaryRequiresStableProcessAndCleanMetrics(t *testing.T) {
	supportedVectors := 3 * len(namedProductionCaseIDs(t))
	coldStartRequests := supportedVectors + 2*3
	summary := proofSummary{
		Inventory: inventorySummary{UniqueContracts: 3, SupportedVectors: supportedVectors},
		ColdStart: coldStartSummary{
			Contracts: 3, Requests: coldStartRequests, Succeeded: coldStartRequests,
			ColdLoads: 3, WarmLoads: uint64(supportedVectors), WaitedLoads: 3,
			ChildGenerationStart: 1, ChildGenerationEnd: 1,
			RSSBaselineBytes: 32 << 20, RSSPeakBytes: 600 << 20,
			RSSEndBytes: 520 << 20, RSSLimitBytes: 1024 << 20,
			Metrics: planMetricsSummary{Started: uint64(coldStartRequests), Succeeded: uint64(coldStartRequests)},
		},
		Preload: preloadSummary{
			Requested: 3, Cold: 3, RepeatWarm: 3,
			MetricColdLoads: 3, MetricWarmLoads: 3,
		},
		Load: loadSummary{
			TargetQPS: 25, Requests: 375, Succeeded: 375,
			CoveredVectors: supportedVectors, AchievedStartQPS: 25,
			ContractLoads: contractLoadSummary{Warm: 375},
		},
		Process: processSummary{
			ChildGenerationStart: 1,
			ChildGenerationEnd:   1,
			RSSBaselineBytes:     32 << 20,
			RSSPostPreloadBytes:  512 << 20,
			RSSPeakBytes:         576 << 20,
			RSSLoadPeakBytes:     576 << 20,
			RSSEndBytes:          520 << 20,
			RSSLimitBytes:        1024 << 20,
			RSSGrowthLimitBytes:  128 << 20,
		},
		Metrics: planMetricsSummary{Started: 375, Succeeded: 375},
	}
	if err := validateSummary(summary); err != nil {
		t.Fatalf("clean proof rejected: %v", err)
	}
	summary.Process.Restarts = 1
	summary.Metrics.AtCapacity = 1
	if err := validateSummary(summary); err == nil {
		t.Fatal("restart and overload were accepted")
	}
}

func namedProductionCaseIDs(t *testing.T) []string {
	t.Helper()
	encoded, err := os.ReadFile(filepath.Join(
		"..", "..", "..", "fixtures", "prompt-contract", "v1", "corpus.json"))
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		SchemaVersion uint32 `json:"schema_version"`
		Cases         []struct {
			ID string `json:"id"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	if corpus.SchemaVersion != 1 || len(corpus.Cases) == 0 {
		t.Fatalf("invalid named prompt case corpus: schema=%d cases=%d",
			corpus.SchemaVersion, len(corpus.Cases))
	}
	ids := make([]string, 0, len(corpus.Cases))
	seen := make(map[string]struct{}, len(corpus.Cases))
	for _, fixture := range corpus.Cases {
		if fixture.ID == "" {
			t.Fatal("named prompt case has an empty ID")
		}
		if _, duplicate := seen[fixture.ID]; duplicate {
			t.Fatalf("duplicate named prompt case %q", fixture.ID)
		}
		seen[fixture.ID] = struct{}{}
		ids = append(ids, fixture.ID)
	}
	return ids
}

func TestPrivateRuntimeDirectoryLeavesRoomForDarwinUnixSocket(t *testing.T) {
	directory, err := privateRuntimeDirectory()
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	info, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("runtime directory mode = %o, want 700", info.Mode().Perm())
	}
	if socket := filepath.Join(directory, "promptsidecar.sock"); len(socket) > 100 {
		t.Fatalf("Unix socket path leaves no SUN_LEN headroom: %q", socket)
	}
}

type staticPlanClient struct {
	plan promptcontract.Plan
	err  error
}

func (c staticPlanClient) Plan(context.Context, promptcontract.PlanInput) (promptcontract.Plan, error) {
	return c.plan, c.err
}
