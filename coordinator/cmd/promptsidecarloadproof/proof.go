package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func runProof(ctx context.Context, args arguments) (proofSummary, error) {
	summary := proofSummary{SchemaVersion: proofSchemaVersion}
	if err := validateArguments(args); err != nil {
		return summary, err
	}
	inventory, err := readProductionInventory(args.VectorsPath)
	if err != nil {
		return summary, err
	}
	summary.Inventory = inventorySummary{
		Models:            inventory.Models,
		EligibleModels:    inventory.EligibleModels,
		UniqueContracts:   len(inventory.Contracts),
		ColdOnlyContracts: inventory.ColdOnlyContracts,
		SupportedVectors:  len(inventory.Vectors),
	}

	runtimeRoot, err := privateRuntimeDirectory()
	if err != nil {
		return summary, err
	}
	defer os.RemoveAll(runtimeRoot)
	summary.ColdStart, err = runColdStartProof(ctx, args, inventory, runtimeRoot)
	if err != nil {
		return summary, fmt.Errorf("real-contract cold-start proof: %w", err)
	}

	config := proofSupervisorConfig(
		args,
		filepath.Join(runtimeRoot, "promptsidecar.sock"),
		len(inventory.Contracts),
		8,
	)
	if err := config.Check(); err != nil {
		return summary, fmt.Errorf("load-proof supervisor configuration: %w", err)
	}
	supervisor := promptcontract.NewSupervisor(config)
	supervisor.Start(ctx)
	defer supervisor.Close()
	liveStatus, err := waitForLive(ctx, supervisor, config.StartupTimeout+10*time.Second)
	if err != nil {
		return summary, err
	}
	allSampler := newRSSSampler(supervisor, 25*time.Millisecond, liveStatus.RSSBytes)
	allSampler.Start(ctx)
	allSamplerStopped := false
	defer func() {
		if !allSamplerStopped {
			allSampler.Stop()
		}
	}()

	preloadCtx, preloadCancel := context.WithTimeout(ctx, config.PreloadTimeout)
	coldPreload, err := supervisor.Client().Preload(preloadCtx, inventory.Contracts)
	preloadCancel()
	if err != nil {
		return summary, fmt.Errorf("cold production-contract preload: %w", err)
	}
	if _, err := waitForReady(ctx, supervisor, 5*time.Second); err != nil {
		return summary, err
	}
	preloadCtx, preloadCancel = context.WithTimeout(ctx, config.PreloadTimeout)
	warmPreload, err := supervisor.Client().Preload(preloadCtx, inventory.Contracts)
	preloadCancel()
	if err != nil {
		return summary, fmt.Errorf("idempotent production-contract preload: %w", err)
	}
	if _, err := waitForReady(ctx, supervisor, 5*time.Second); err != nil {
		return summary, err
	}
	summary.Preload = preloadSummary{
		Requested:       coldPreload.Requested,
		Warm:            coldPreload.Warm,
		Cold:            coldPreload.Cold,
		Failed:          coldPreload.Failed,
		RepeatWarm:      warmPreload.Warm,
		RepeatCold:      warmPreload.Cold,
		RepeatFailed:    warmPreload.Failed,
		MetricColdLoads: warmPreload.Metrics.ContractLoads.Cold,
		MetricWarmLoads: warmPreload.Metrics.ContractLoads.Warm,
		MetricLoadWaits: warmPreload.Metrics.ContractLoads.Waited,
	}
	metricsBefore, err := supervisor.Client().Metrics(ctx)
	if err != nil {
		return summary, fmt.Errorf("read pre-load metrics: %w", err)
	}
	statusBefore := supervisor.Status()
	statsBefore := supervisor.Client().Stats()
	loadSampler := newRSSSampler(supervisor, 25*time.Millisecond, statusBefore.RSSBytes)
	loadSampler.Start(ctx)

	load, loadErr := runProductionLoad(ctx, supervisor.Client(), inventory.Vectors, loadConfig{
		QPS:            args.QPS,
		Duration:       args.Duration,
		RequestTimeout: 2 * time.Second,
	})
	if loadErr != nil {
		loadSampler.Stop()
		allSampler.Stop()
		allSamplerStopped = true
		return summary, fmt.Errorf("run production load: %w", loadErr)
	}
	metricsAfter, err := supervisor.Client().Metrics(ctx)
	if err != nil {
		loadSampler.Stop()
		allSampler.Stop()
		allSamplerStopped = true
		return summary, fmt.Errorf("read post-load metrics: %w", err)
	}
	loadPeakRSS := loadSampler.Stop()
	peakRSS := allSampler.Stop()
	allSamplerStopped = true
	summary.Load = loadSummary{
		TargetQPS:          args.QPS,
		DurationMS:         args.Duration.Milliseconds(),
		Requests:           load.Requests,
		Succeeded:          load.Succeeded,
		Errors:             load.Errors,
		Mismatches:         load.Mismatches,
		CoveredVectors:     load.CoveredVectors,
		AchievedStartQPS:   load.AchievedStartQPS,
		MaximumScheduleLag: load.MaximumScheduleLag.Milliseconds(),
		ContractLoads: contractLoadSummary{
			Cold:   counterDelta(metricsBefore.Metrics.ContractLoads.Cold, metricsAfter.Metrics.ContractLoads.Cold),
			Warm:   counterDelta(metricsBefore.Metrics.ContractLoads.Warm, metricsAfter.Metrics.ContractLoads.Warm),
			Waited: counterDelta(metricsBefore.Metrics.ContractLoads.Waited, metricsAfter.Metrics.ContractLoads.Waited),
			Failed: counterDelta(metricsBefore.Metrics.ContractLoads.Failed, metricsAfter.Metrics.ContractLoads.Failed),
		},
		FailureSamples: load.FailureSamples,
	}
	statusAfter := supervisor.Status()
	statsAfter := supervisor.Client().Stats()
	summary.Process = processSummary{
		ChildGenerationStart: liveStatus.ChildGeneration,
		ChildGenerationEnd:   statusAfter.ChildGeneration,
		Restarts:             statusAfter.Restarts,
		RSSBaselineBytes:     liveStatus.RSSBytes,
		RSSPostPreloadBytes:  statusBefore.RSSBytes,
		RSSPeakBytes:         peakRSS,
		RSSLoadPeakBytes:     loadPeakRSS,
		RSSEndBytes:          statusAfter.RSSBytes,
		RSSLimitBytes:        uint64(args.MaxRSSMiB) << 20,
		RSSGrowthLimitBytes:  uint64(args.MaxRSSGrowthMiB) << 20,
	}
	summary.Metrics = planMetricDelta(metricsBefore.Metrics.Plans, metricsAfter.Metrics.Plans)
	summary.Metrics.ClientTimeouts = counterDelta(statsBefore.Timeouts, statsAfter.Timeouts)
	summary.Metrics.HealthTimeouts = counterDelta(statsBefore.HealthTimeouts, statsAfter.HealthTimeouts)
	summary.Metrics.PreloadTimeouts = counterDelta(statsBefore.PreloadTimeouts, statsAfter.PreloadTimeouts)
	summary.Metrics.Overloads = counterDelta(statsBefore.Overloads, statsAfter.Overloads)
	if err := validateSummary(summary); err != nil {
		return summary, err
	}
	summary.Passed = true
	return summary, nil
}

func validateArguments(args arguments) error {
	if !filepath.IsAbs(args.BinaryPath) || !filepath.IsAbs(args.ArtifactRoot) ||
		!filepath.IsAbs(args.VectorsPath) {
		return errors.New("binary, artifact-root, and vectors paths must be absolute")
	}
	if args.QPS < 25 || args.QPS > maxLoadQPS ||
		args.Duration < 15*time.Second || args.Duration > time.Minute {
		return errors.New("production load proof requires at least 25 QPS for 15 seconds")
	}
	if args.MaxRSSMiB < 256 || args.MaxRSSMiB > 16<<10 ||
		args.MaxRSSGrowthMiB <= 0 || args.MaxRSSGrowthMiB > args.MaxRSSMiB {
		return errors.New("invalid RSS bounds")
	}
	info, err := os.Stat(args.BinaryPath)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0o111 == 0 {
		return errors.New("release sidecar binary is not an executable regular file")
	}
	if info, err = os.Stat(args.ArtifactRoot); err != nil || !info.IsDir() {
		return errors.New("prompt artifact root is not a directory")
	}
	return nil
}

func privateRuntimeDirectory() (string, error) {
	// Darwin's TMPDIR lives under a long /var/folders path that can exceed the
	// Unix-domain SUN_LEN once the socket filename is appended. Resolve /tmp to
	// its real short directory instead; the child still gets a private 0700
	// leaf and validates every ancestor before binding.
	base, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		return "", fmt.Errorf("resolve temporary directory: %w", err)
	}
	directory, err := os.MkdirTemp(base, "promptsidecar-load-proof-")
	if err != nil {
		return "", fmt.Errorf("create private runtime directory: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		_ = os.RemoveAll(directory)
		return "", fmt.Errorf("secure private runtime directory: %w", err)
	}
	return directory, nil
}

func waitForReady(
	ctx context.Context,
	supervisor *promptcontract.Supervisor,
	timeout time.Duration,
) (promptcontract.SupervisorStatus, error) {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		status := supervisor.Status()
		if status.Restarts != 0 {
			return status, fmt.Errorf("sidecar restarted before readiness: %+v", status)
		}
		if status.Running && status.Ready && status.ChildGeneration != 0 && status.RSSBytes != 0 {
			return status, nil
		}
		select {
		case <-ctx.Done():
			return status, ctx.Err()
		case <-deadline.C:
			return status, fmt.Errorf("sidecar did not become measurable and ready: %+v", status)
		case <-ticker.C:
		}
	}
}

func waitForLive(
	ctx context.Context,
	supervisor *promptcontract.Supervisor,
	timeout time.Duration,
) (promptcontract.SupervisorStatus, error) {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		status := supervisor.Status()
		if status.Restarts != 0 {
			return status, fmt.Errorf("sidecar restarted before liveness: %+v", status)
		}
		if status.Running && status.ChildGeneration != 0 && status.RSSBytes != 0 {
			if err := supervisor.Client().Health(ctx); err == nil {
				return status, nil
			}
		}
		select {
		case <-ctx.Done():
			return status, ctx.Err()
		case <-deadline.C:
			return status, fmt.Errorf("sidecar did not become measurable and live: %+v", status)
		case <-ticker.C:
		}
	}
}
