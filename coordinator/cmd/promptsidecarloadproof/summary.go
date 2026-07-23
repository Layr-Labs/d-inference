package main

import (
	"errors"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

const proofSchemaVersion = 1

const maximumProofScheduleLag = 250 * time.Millisecond

type proofSummary struct {
	SchemaVersion int                `json:"schema_version"`
	Passed        bool               `json:"passed"`
	Inventory     inventorySummary   `json:"inventory"`
	ColdStart     coldStartSummary   `json:"cold_start"`
	Preload       preloadSummary     `json:"preload"`
	Load          loadSummary        `json:"load"`
	Process       processSummary     `json:"process"`
	Metrics       planMetricsSummary `json:"metrics"`
	Error         string             `json:"error,omitempty"`
}

type inventorySummary struct {
	Models            int `json:"models"`
	EligibleModels    int `json:"eligible_models"`
	UniqueContracts   int `json:"unique_contracts"`
	ColdOnlyContracts int `json:"cold_only_contracts"`
	SupportedVectors  int `json:"supported_vectors"`
}

type preloadSummary struct {
	Requested       int    `json:"requested"`
	Warm            int    `json:"warm"`
	Cold            int    `json:"cold"`
	Failed          int    `json:"failed"`
	RepeatWarm      int    `json:"repeat_warm"`
	RepeatCold      int    `json:"repeat_cold"`
	RepeatFailed    int    `json:"repeat_failed"`
	MetricColdLoads uint64 `json:"metric_cold_loads"`
	MetricWarmLoads uint64 `json:"metric_warm_loads"`
	MetricLoadWaits uint64 `json:"metric_load_waits"`
}

type coldStartSummary struct {
	Contracts            int                `json:"contracts"`
	Requests             int                `json:"requests"`
	Succeeded            int                `json:"succeeded"`
	ColdOnlyRejections   int                `json:"cold_only_rejections"`
	Errors               int                `json:"errors"`
	Mismatches           int                `json:"mismatches"`
	ColdLoads            uint64             `json:"cold_loads"`
	WarmLoads            uint64             `json:"warm_loads"`
	WaitedLoads          uint64             `json:"waited_loads"`
	FailedLoads          uint64             `json:"failed_loads"`
	ChildGenerationStart uint64             `json:"child_generation_start"`
	ChildGenerationEnd   uint64             `json:"child_generation_end"`
	Restarts             uint64             `json:"restarts"`
	RSSBaselineBytes     uint64             `json:"rss_baseline_bytes"`
	RSSPeakBytes         uint64             `json:"rss_peak_bytes"`
	RSSEndBytes          uint64             `json:"rss_end_bytes"`
	RSSLimitBytes        uint64             `json:"rss_limit_bytes"`
	Metrics              planMetricsSummary `json:"metrics"`
	FailureSamples       []string           `json:"failure_samples,omitempty"`
}

type contractLoadSummary struct {
	Cold   uint64 `json:"cold"`
	Warm   uint64 `json:"warm"`
	Waited uint64 `json:"waited"`
	Failed uint64 `json:"failed"`
}

type loadSummary struct {
	TargetQPS          int                 `json:"target_qps"`
	DurationMS         int64               `json:"duration_ms"`
	Requests           int                 `json:"requests"`
	Succeeded          int                 `json:"succeeded"`
	Errors             int                 `json:"errors"`
	Mismatches         int                 `json:"mismatches"`
	CoveredVectors     int                 `json:"covered_vectors"`
	AchievedStartQPS   float64             `json:"achieved_start_qps"`
	MaximumScheduleLag int64               `json:"maximum_schedule_lag_ms"`
	ContractLoads      contractLoadSummary `json:"contract_loads"`
	FailureSamples     []string            `json:"failure_samples,omitempty"`
}

type processSummary struct {
	ChildGenerationStart uint64 `json:"child_generation_start"`
	ChildGenerationEnd   uint64 `json:"child_generation_end"`
	Restarts             uint64 `json:"restarts"`
	RSSBaselineBytes     uint64 `json:"rss_baseline_bytes"`
	RSSPostPreloadBytes  uint64 `json:"rss_post_preload_bytes"`
	RSSPeakBytes         uint64 `json:"rss_peak_bytes"`
	RSSLoadPeakBytes     uint64 `json:"rss_load_peak_bytes"`
	RSSEndBytes          uint64 `json:"rss_end_bytes"`
	RSSLimitBytes        uint64 `json:"rss_limit_bytes"`
	RSSGrowthLimitBytes  uint64 `json:"rss_growth_limit_bytes"`
}

type planMetricsSummary struct {
	Started         uint64 `json:"started"`
	Succeeded       uint64 `json:"succeeded"`
	ColdOnly        uint64 `json:"cold_only"`
	Failed          uint64 `json:"failed"`
	AtCapacity      uint64 `json:"at_capacity"`
	NotReady        uint64 `json:"not_ready"`
	TimedOut        uint64 `json:"timed_out"`
	ClientTimeouts  uint64 `json:"client_timeouts"`
	HealthTimeouts  uint64 `json:"health_timeouts"`
	PreloadTimeouts uint64 `json:"preload_timeouts"`
	Overloads       uint64 `json:"overloads"`
}

func planMetricDelta(
	before, after promptcontract.SidecarPlanMetrics,
) planMetricsSummary {
	return planMetricsSummary{
		Started:    counterDelta(before.Started, after.Started),
		Succeeded:  counterDelta(before.Succeeded, after.Succeeded),
		ColdOnly:   counterDelta(before.ColdOnly, after.ColdOnly),
		Failed:     counterDelta(before.Failed, after.Failed),
		AtCapacity: counterDelta(before.AtCapacity, after.AtCapacity),
		NotReady:   counterDelta(before.NotReady, after.NotReady),
		TimedOut:   counterDelta(before.TimedOut, after.TimedOut),
	}
}

func counterDelta(before, after uint64) uint64 {
	if after < before {
		return 0
	}
	return after - before
}

func validateSummary(summary proofSummary) error {
	var failures []string
	expectedColdOnlyRejections := summary.Inventory.ColdOnlyContracts * coldBurstPerContract
	if summary.ColdStart.Contracts != summary.Inventory.UniqueContracts ||
		summary.ColdStart.Requests != summary.Inventory.UniqueContracts*coldBurstPerContract ||
		summary.ColdStart.Succeeded+summary.ColdStart.ColdOnlyRejections != summary.ColdStart.Requests ||
		summary.ColdStart.ColdOnlyRejections != expectedColdOnlyRejections ||
		summary.ColdStart.Errors != 0 || summary.ColdStart.Mismatches != 0 ||
		summary.ColdStart.ColdLoads != uint64(summary.Inventory.UniqueContracts) ||
		summary.ColdStart.FailedLoads != 0 || summary.ColdStart.WaitedLoads == 0 ||
		summary.ColdStart.ColdLoads+summary.ColdStart.WarmLoads+summary.ColdStart.WaitedLoads !=
			uint64(summary.ColdStart.Requests) {
		failures = append(failures, "real-contract concurrent cold loads did not singleflight cleanly")
	}
	if summary.ColdStart.Restarts != 0 || summary.ColdStart.ChildGenerationStart == 0 ||
		summary.ColdStart.ChildGenerationStart != summary.ColdStart.ChildGenerationEnd ||
		summary.ColdStart.RSSBaselineBytes == 0 || summary.ColdStart.RSSEndBytes == 0 ||
		summary.ColdStart.RSSPeakBytes > summary.ColdStart.RSSLimitBytes {
		failures = append(failures, "cold-start sidecar restarted or exceeded its RSS bound")
	}
	if summary.ColdStart.Metrics.Started != uint64(summary.ColdStart.Requests) ||
		summary.ColdStart.Metrics.Succeeded != uint64(summary.ColdStart.Succeeded) ||
		summary.ColdStart.Metrics.ColdOnly != uint64(summary.ColdStart.ColdOnlyRejections) ||
		summary.ColdStart.Metrics.Failed != 0 ||
		summary.ColdStart.Metrics.AtCapacity != 0 ||
		summary.ColdStart.Metrics.NotReady != 0 || summary.ColdStart.Metrics.TimedOut != 0 ||
		summary.ColdStart.Metrics.ClientTimeouts != 0 ||
		summary.ColdStart.Metrics.HealthTimeouts != 0 ||
		summary.ColdStart.Metrics.PreloadTimeouts != 0 || summary.ColdStart.Metrics.Overloads != 0 {
		failures = append(failures, "cold-start plan metrics recorded failures, overload, or timeouts")
	}
	if summary.Preload.Requested != summary.Inventory.UniqueContracts ||
		summary.Preload.Cold != summary.Inventory.UniqueContracts ||
		summary.Preload.Warm != 0 || summary.Preload.Failed != 0 {
		failures = append(failures, "explicit active-set preload was not one cold load per contract")
	}
	if summary.Preload.RepeatWarm != summary.Inventory.UniqueContracts ||
		summary.Preload.RepeatCold != 0 || summary.Preload.RepeatFailed != 0 ||
		summary.Preload.MetricColdLoads != uint64(summary.Inventory.UniqueContracts) ||
		summary.Preload.MetricWarmLoads != uint64(summary.Inventory.UniqueContracts) ||
		summary.Preload.MetricLoadWaits != 0 {
		failures = append(failures, "idempotent preload did not find every active contract warm")
	}
	if summary.Load.Requests == 0 || summary.Load.Succeeded != summary.Load.Requests ||
		summary.Load.Errors != 0 || summary.Load.Mismatches != 0 ||
		summary.Load.CoveredVectors != summary.Inventory.SupportedVectors {
		failures = append(failures, "production vectors did not all plan successfully")
	}
	if summary.Load.ContractLoads.Cold != 0 || summary.Load.ContractLoads.Waited != 0 ||
		summary.Load.ContractLoads.Failed != 0 ||
		summary.Load.ContractLoads.Warm != uint64(summary.Load.Requests) {
		failures = append(failures, "sustained production load reloaded or missed a warm contract")
	}
	if summary.Load.AchievedStartQPS < float64(summary.Load.TargetQPS)*0.95 {
		failures = append(failures, "actual request start rate fell below 95 percent of target")
	}
	if summary.Load.AchievedStartQPS > float64(summary.Load.TargetQPS)*1.05 ||
		time.Duration(summary.Load.MaximumScheduleLag)*time.Millisecond > maximumProofScheduleLag {
		failures = append(failures, "production load caught up in a burst instead of sustaining its target rate")
	}
	if summary.Process.Restarts != 0 || summary.Process.ChildGenerationStart == 0 ||
		summary.Process.ChildGenerationStart != summary.Process.ChildGenerationEnd {
		failures = append(failures, "sidecar child restarted or changed generation")
	}
	if summary.Process.RSSBaselineBytes == 0 || summary.Process.RSSPostPreloadBytes == 0 ||
		summary.Process.RSSEndBytes == 0 ||
		summary.Process.RSSPeakBytes > summary.Process.RSSLimitBytes ||
		summary.Process.RSSLoadPeakBytes >
			summary.Process.RSSPostPreloadBytes+summary.Process.RSSGrowthLimitBytes {
		failures = append(failures, "sidecar RSS was unmeasurable or escaped its bound")
	}
	if summary.Metrics.Started != uint64(summary.Load.Requests) ||
		summary.Metrics.Succeeded != uint64(summary.Load.Requests) ||
		summary.Metrics.ColdOnly != 0 || summary.Metrics.Failed != 0 ||
		summary.Metrics.AtCapacity != 0 ||
		summary.Metrics.NotReady != 0 || summary.Metrics.TimedOut != 0 ||
		summary.Metrics.ClientTimeouts != 0 || summary.Metrics.HealthTimeouts != 0 ||
		summary.Metrics.PreloadTimeouts != 0 || summary.Metrics.Overloads != 0 {
		failures = append(failures, "sidecar/client metrics recorded failures, overload, or timeouts")
	}
	if len(failures) != 0 {
		return errors.New(strings.Join(failures, "; "))
	}
	return nil
}
