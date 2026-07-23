package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

const coldBurstPerContract = 16

type coldProbe struct {
	vector              planVector
	exactMatch          bool
	expectDynamicReject bool
}

func runColdStartProof(
	ctx context.Context,
	args arguments,
	inventory productionInventory,
	runtimeRoot string,
) (coldStartSummary, error) {
	var summary coldStartSummary
	if len(inventory.Contracts) < 2 {
		return summary, errors.New("cold-start proof requires at least two real contracts")
	}
	config := proofSupervisorConfig(
		args,
		filepath.Join(runtimeRoot, "promptsidecar-cold.sock"),
		len(inventory.Contracts)-1,
		coldBurstPerContract,
	)
	if err := config.Check(); err != nil {
		return summary, fmt.Errorf("cold-start supervisor configuration: %w", err)
	}
	supervisor := promptcontract.NewSupervisor(config)
	supervisor.Start(ctx)
	defer supervisor.Close()
	live, err := waitForLive(ctx, supervisor, config.StartupTimeout+10*time.Second)
	if err != nil {
		return summary, err
	}
	sampler := newRSSSampler(supervisor, 25*time.Millisecond, live.RSSBytes)
	sampler.Start(ctx)
	stopped := false
	defer func() {
		if !stopped {
			sampler.Stop()
		}
	}()

	// Load one real contract solely to open the isolated proof process. The LRU
	// is one slot smaller than the real active set, so the ordered bursts below
	// evict and then cold-load every contract, including this first one.
	preloadCtx, cancel := context.WithTimeout(ctx, config.PreloadTimeout)
	initial, err := supervisor.Client().Preload(preloadCtx, inventory.Contracts[:1])
	cancel()
	if err != nil {
		return summary, fmt.Errorf("seed cold-start preload: %w", err)
	}
	if !initial.Ready || initial.Cold != 1 || initial.Failed != 0 {
		return summary, fmt.Errorf("seed cold-start preload failed: report=%+v", initial)
	}
	if _, err := waitForReady(ctx, supervisor, 5*time.Second); err != nil {
		return summary, err
	}
	metricsBefore, err := supervisor.Client().Metrics(ctx)
	if err != nil {
		return summary, fmt.Errorf("read cold-start metrics: %w", err)
	}
	statsBefore := supervisor.Client().Stats()

	probes := coldProbes(inventory)
	order := append([]string(nil), inventory.Contracts[1:]...)
	order = append(order, inventory.Contracts[0])
	var report coldBurstReport
	for _, contractID := range order {
		probe, ok := probes[contractID]
		if !ok {
			return summary, fmt.Errorf("no cold probe for contract %s", contractID)
		}
		burst := runColdBurst(ctx, supervisor.Client(), probe, coldBurstPerContract)
		report.add(burst)
	}

	metricsAfter, err := supervisor.Client().Metrics(ctx)
	if err != nil {
		return summary, fmt.Errorf("read post-cold-start metrics: %w", err)
	}
	statsAfter := supervisor.Client().Stats()
	statusAfter := supervisor.Status()
	peakRSS := sampler.Stop()
	stopped = true
	summary = coldStartSummary{
		Contracts:            len(inventory.Contracts),
		Requests:             report.Requests,
		Succeeded:            report.Succeeded,
		ColdOnlyRejections:   report.ColdOnlyRejections,
		Errors:               report.Errors,
		Mismatches:           report.Mismatches,
		ColdLoads:            counterDelta(metricsBefore.Metrics.ContractLoads.Cold, metricsAfter.Metrics.ContractLoads.Cold),
		WarmLoads:            counterDelta(metricsBefore.Metrics.ContractLoads.Warm, metricsAfter.Metrics.ContractLoads.Warm),
		WaitedLoads:          counterDelta(metricsBefore.Metrics.ContractLoads.Waited, metricsAfter.Metrics.ContractLoads.Waited),
		FailedLoads:          counterDelta(metricsBefore.Metrics.ContractLoads.Failed, metricsAfter.Metrics.ContractLoads.Failed),
		ChildGenerationStart: live.ChildGeneration,
		ChildGenerationEnd:   statusAfter.ChildGeneration,
		Restarts:             statusAfter.Restarts,
		RSSBaselineBytes:     live.RSSBytes,
		RSSPeakBytes:         peakRSS,
		RSSEndBytes:          statusAfter.RSSBytes,
		RSSLimitBytes:        uint64(args.MaxRSSMiB) << 20,
		FailureSamples:       report.FailureSamples,
	}
	summary.Metrics = planMetricDelta(metricsBefore.Metrics.Plans, metricsAfter.Metrics.Plans)
	summary.Metrics.ClientTimeouts = counterDelta(statsBefore.Timeouts, statsAfter.Timeouts)
	summary.Metrics.HealthTimeouts = counterDelta(statsBefore.HealthTimeouts, statsAfter.HealthTimeouts)
	summary.Metrics.PreloadTimeouts = counterDelta(statsBefore.PreloadTimeouts, statsAfter.PreloadTimeouts)
	summary.Metrics.Overloads = counterDelta(statsBefore.Overloads, statsAfter.Overloads)
	return summary, nil
}

func coldProbes(inventory productionInventory) map[string]coldProbe {
	probes := make(map[string]coldProbe, len(inventory.Contracts))
	for _, vector := range inventory.Vectors {
		if _, exists := probes[vector.PromptContractID]; !exists {
			probes[vector.PromptContractID] = coldProbe{vector: vector, exactMatch: true}
		}
	}
	for _, contractID := range inventory.Contracts {
		if _, exists := probes[contractID]; exists {
			continue
		}
		probes[contractID] = coldProbe{expectDynamicReject: true, vector: planVector{
			Name:             "real-contract/" + contractID[:12],
			PromptContractID: contractID,
			ScopeID:          "cold-start-load-proof",
			ProviderBody: json.RawMessage(
				`{"model":"load-proof","messages":[{"role":"user","content":"cold-start singleflight probe"}]}`),
		}}
	}
	return probes
}

type coldBurstReport struct {
	Requests           int
	Succeeded          int
	ColdOnlyRejections int
	Errors             int
	Mismatches         int
	FailureSamples     []string
}

func (r *coldBurstReport) add(other coldBurstReport) {
	r.Requests += other.Requests
	r.Succeeded += other.Succeeded
	r.ColdOnlyRejections += other.ColdOnlyRejections
	r.Errors += other.Errors
	r.Mismatches += other.Mismatches
	for _, failure := range other.FailureSamples {
		if len(r.FailureSamples) >= maxFailureSamples {
			break
		}
		r.FailureSamples = append(r.FailureSamples, failure)
	}
}

func runColdBurst(
	ctx context.Context,
	client planClient,
	probe coldProbe,
	requests int,
) coldBurstReport {
	results := make(chan planResult, requests)
	start := make(chan struct{})
	var workers sync.WaitGroup
	for range requests {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			requestCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
			defer cancel()
			actual, err := client.Plan(requestCtx, promptcontract.PlanInput{
				PromptContractID: probe.vector.PromptContractID,
				ScopeID:          probe.vector.ScopeID,
				Endpoint:         promptcontract.EndpointChatCompletions,
				Body:             probe.vector.ProviderBody,
			})
			result := planResult{vectorName: probe.vector.Name, err: err}
			if probe.expectDynamicReject && errors.Is(err, promptcontract.ErrDynamicContract) {
				result.expectedReject = true
				result.err = nil
			}
			if err == nil {
				switch {
				case !actual.Participating:
					result.mismatch = "plan did not participate"
				case actual.PromptContractID != probe.vector.PromptContractID:
					result.mismatch = "prompt contract differs"
				case probe.exactMatch:
					result.mismatch = planDifference(probe.vector.Expected, actual)
				}
			}
			results <- result
		}()
	}
	close(start)
	workers.Wait()
	close(results)

	report := coldBurstReport{Requests: requests}
	for result := range results {
		switch {
		case result.expectedReject:
			report.ColdOnlyRejections++
		case result.err != nil:
			report.Errors++
			if len(report.FailureSamples) < maxFailureSamples {
				report.FailureSamples = append(report.FailureSamples,
					fmt.Sprintf("%s: %v", result.vectorName, result.err))
			}
		case result.mismatch != "":
			report.Mismatches++
			if len(report.FailureSamples) < maxFailureSamples {
				report.FailureSamples = append(report.FailureSamples,
					fmt.Sprintf("%s: %s", result.vectorName, result.mismatch))
			}
		default:
			report.Succeeded++
		}
	}
	return report
}
