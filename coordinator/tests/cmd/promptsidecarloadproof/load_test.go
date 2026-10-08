package main_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	promptproof "github.com/eigeninference/d-inference/coordinator/internal/promptproof"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestProductionInventoryCoversSevenModelsAndEverySupportedVector(t *testing.T) {
	inventory, err := promptproof.ReadProductionInventory(filepath.Join(
		"..", "..", "..", "..", "fixtures", "prompt-contract", "v1", "production_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if inventory.Models != 7 || inventory.EligibleModels != 7 || inventory.ColdOnlyContracts != 0 {
		t.Fatalf("model inventory: models=%d eligible=%d cold-only=%d, want 7/7/0",
			inventory.Models, inventory.EligibleModels, inventory.ColdOnlyContracts)
	}
	if len(inventory.Contracts) != 6 {
		t.Fatalf("deduplicated contracts = %d, want 6", len(inventory.Contracts))
	}
	if len(inventory.Vectors) != 154 {
		t.Fatalf("supported vectors = %d, want 154", len(inventory.Vectors))
	}
	coveredModels := make(map[string]bool)
	coveredCases := make(map[string]bool)
	for _, vector := range inventory.Vectors {
		coveredModels[vector.ModelID] = true
		coveredCases[vector.Name] = true
	}
	if len(coveredModels) != inventory.EligibleModels {
		t.Fatalf("covered routable models = %d, want %d", len(coveredModels), inventory.EligibleModels)
	}
	for modelID := range coveredModels {
		for _, caseID := range []string{"json_object", "json_schema", "response_text", "multi_system"} {
			if !coveredCases[modelID+"/"+caseID] {
				t.Fatalf("serving-preparation vector %s/%s missing from load inventory", modelID, caseID)
			}
		}
	}
}

func TestProductionInventoryRejectsIncompleteModelSet(t *testing.T) {
	_, err := promptproof.ValidateProductionCorpus(promptproof.Corpus{SchemaVersion: 1})
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
	report, err := promptproof.RunProductionLoad(context.Background(), client, []promptproof.PlanVector{{
		Name:             "model/case",
		PromptContractID: contractID,
		ScopeID:          "scope",
		ProviderBody:     []byte(`{"model":"model","messages":[]}`),
		Expected:         expected,
	}}, promptproof.LoadConfig{
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
	_, err := promptproof.RunProductionLoad(
		context.Background(), staticPlanClient{}, []promptproof.PlanVector{{Name: "vector"}},
		promptproof.LoadConfig{QPS: 1_001, Duration: time.Second, RequestTimeout: time.Second},
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
	if difference := promptproof.PlanDifference(expected, expected); difference != "plan did not participate" {
		t.Fatalf("non-participating difference = %q", difference)
	}
	actual := expected
	actual.Participating = true
	if difference := promptproof.PlanDifference(expected, actual); difference != "" {
		t.Fatalf("matching plan difference = %q", difference)
	}
	actual.PromptTokenCount++
	if difference := promptproof.PlanDifference(expected, actual); difference == "" {
		t.Fatal("mismatched plan was accepted")
	}
}

func TestValidateSummaryRequiresStableProcessAndCleanMetrics(t *testing.T) {
	summary := promptproof.Summary{
		Inventory: promptproof.InventorySummary{UniqueContracts: 3, SupportedVectors: 42},
		ColdStart: promptproof.ColdStartSummary{
			Contracts: 3, Requests: 48, Succeeded: 48,
			ColdLoads: 3, PreloadRotations: 3, WarmLoads: 48,
			ChildGenerationStart: 1, ChildGenerationEnd: 1,
			RSSBaselineBytes: 32 << 20, RSSPeakBytes: 600 << 20,
			RSSEndBytes: 520 << 20, RSSLimitBytes: 1024 << 20,
			Metrics: promptproof.PlanMetricsSummary{Started: 48, Succeeded: 48},
		},
		Preload: promptproof.PreloadSummary{
			Requested: 3, Cold: 3, RepeatWarm: 3,
			MetricColdLoads: 3, MetricWarmLoads: 3,
		},
		Load: promptproof.LoadSummary{
			TargetQPS: 25, Requests: 375, Succeeded: 375,
			CoveredVectors: 42, AchievedStartQPS: 25,
			ContractLoads: promptproof.ContractLoadSummary{Warm: 375},
		},
		Process: promptproof.ProcessSummary{
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
		Metrics: promptproof.PlanMetricsSummary{Started: 375, Succeeded: 375},
	}
	if err := promptproof.ValidateSummary(summary); err != nil {
		t.Fatalf("clean proof rejected: %v", err)
	}
	unadmitted := summary
	unadmitted.ColdStart.PreloadRotations = 0
	if err := promptproof.ValidateSummary(unadmitted); err == nil {
		t.Fatal("cold plans without explicit preload admission were accepted")
	}
	missingLoad := summary
	missingLoad.ColdStart.ColdLoads--
	if err := promptproof.ValidateSummary(missingLoad); err == nil {
		t.Fatal("missing cold rotation was accepted")
	}
	summary.Process.Restarts = 1
	summary.Metrics.AtCapacity = 1
	if err := promptproof.ValidateSummary(summary); err == nil {
		t.Fatal("restart and overload were accepted")
	}
}

func TestPrivateRuntimeDirectoryLeavesRoomForDarwinUnixSocket(t *testing.T) {
	directory, err := promptproof.PrivateRuntimeDirectory()
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
