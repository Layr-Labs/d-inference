package main

import (
	"context"
	"os"
	"path/filepath"
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
	if len(inventory.Vectors) != 42 {
		t.Fatalf("supported vectors = %d, want 42", len(inventory.Vectors))
	}
	coveredModels := make(map[string]bool)
	for _, vector := range inventory.Vectors {
		coveredModels[vector.ModelID] = true
	}
	if len(coveredModels) != inventory.EligibleModels {
		t.Fatalf("covered routable models = %d, want %d", len(coveredModels), inventory.EligibleModels)
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
	summary := proofSummary{
		Inventory: inventorySummary{UniqueContracts: 3, SupportedVectors: 42},
		ColdStart: coldStartSummary{
			Contracts: 3, Requests: 48, Succeeded: 48,
			ColdLoads: 3, WarmLoads: 42, WaitedLoads: 3,
			ChildGenerationStart: 1, ChildGenerationEnd: 1,
			RSSBaselineBytes: 32 << 20, RSSPeakBytes: 600 << 20,
			RSSEndBytes: 520 << 20, RSSLimitBytes: 1024 << 20,
			Metrics: planMetricsSummary{Started: 48, Succeeded: 48},
		},
		Preload: preloadSummary{
			Requested: 3, Cold: 3, RepeatWarm: 3,
			MetricColdLoads: 3, MetricWarmLoads: 3,
		},
		Load: loadSummary{
			TargetQPS: 25, Requests: 375, Succeeded: 375,
			CoveredVectors: 42, AchievedStartQPS: 25,
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
