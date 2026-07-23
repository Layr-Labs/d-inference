package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

const (
	maxFailureSamples = 10
	maxLoadQPS        = 1_000
	maxLoadRequests   = 10_000
)

type planClient interface {
	Plan(context.Context, promptcontract.PlanInput) (promptcontract.Plan, error)
}

type loadConfig struct {
	QPS            int
	Duration       time.Duration
	RequestTimeout time.Duration
}

type loadReport struct {
	Requests           int
	Succeeded          int
	Errors             int
	Mismatches         int
	CoveredVectors     int
	AchievedStartQPS   float64
	MaximumScheduleLag time.Duration
	FailureSamples     []string
}

type planResult struct {
	vectorName     string
	err            error
	mismatch       string
	expectedReject bool
}

func runProductionLoad(
	ctx context.Context,
	client planClient,
	vectors []planVector,
	config loadConfig,
) (loadReport, error) {
	if client == nil || len(vectors) == 0 || config.QPS <= 0 || config.QPS > maxLoadQPS ||
		config.Duration <= 0 || config.RequestTimeout <= 0 {
		return loadReport{}, errors.New("invalid production-load configuration")
	}
	interval := time.Second / time.Duration(config.QPS)
	requests := int(config.Duration / interval)
	if requests > maxLoadRequests {
		return loadReport{}, fmt.Errorf("load window exceeds %d bounded requests", maxLoadRequests)
	}
	if requests < len(vectors) {
		return loadReport{}, fmt.Errorf(
			"load window covers %d requests, fewer than %d production vectors", requests, len(vectors))
	}

	results := make(chan planResult, requests)
	var workers sync.WaitGroup
	startedAt := time.Now()
	var firstStart, lastStart time.Time
	var maximumLag time.Duration
	for index := range requests {
		target := startedAt.Add(time.Duration(index) * interval)
		if err := waitUntil(ctx, target); err != nil {
			workers.Wait()
			close(results)
			return loadReport{}, err
		}
		actualStart := time.Now()
		if index == 0 {
			firstStart = actualStart
		}
		lastStart = actualStart
		if lag := actualStart.Sub(target); lag > maximumLag {
			maximumLag = lag
		}
		vector := vectors[index%len(vectors)]
		workers.Add(1)
		go func() {
			defer workers.Done()
			requestCtx, cancel := context.WithTimeout(ctx, config.RequestTimeout)
			defer cancel()
			actual, err := client.Plan(requestCtx, promptcontract.PlanInput{
				PromptContractID: vector.PromptContractID,
				ScopeID:          vector.ScopeID,
				// Production lowers every endpoint-native request to the exact
				// provider chat body before planning. Exercise that serving path,
				// while retaining the original endpoint in the fixture name.
				Endpoint: promptcontract.EndpointChatCompletions,
				Body:     vector.ProviderBody,
			})
			result := planResult{vectorName: vector.Name, err: err}
			if err == nil {
				result.mismatch = planDifference(vector.Expected, actual)
			}
			results <- result
		}()
	}
	workers.Wait()
	close(results)

	report := loadReport{Requests: requests, MaximumScheduleLag: maximumLag}
	if requests > 1 && lastStart.After(firstStart) {
		report.AchievedStartQPS = float64(requests-1) / lastStart.Sub(firstStart).Seconds()
	}
	covered := make(map[string]struct{}, len(vectors))
	for result := range results {
		covered[result.vectorName] = struct{}{}
		switch {
		case result.err != nil:
			report.Errors++
			appendFailure(&report, fmt.Sprintf("%s: %v", result.vectorName, result.err))
		case result.mismatch != "":
			report.Mismatches++
			appendFailure(&report, fmt.Sprintf("%s: %s", result.vectorName, result.mismatch))
		default:
			report.Succeeded++
		}
	}
	report.CoveredVectors = len(covered)
	return report, nil
}

func waitUntil(ctx context.Context, target time.Time) error {
	wait := time.Until(target)
	if wait <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func planDifference(expected, actual promptcontract.Plan) string {
	if !actual.Participating {
		return "plan did not participate"
	}
	if actual.PromptContractID != expected.PromptContractID {
		return fmt.Sprintf(
			"prompt contract = %q, want %q", actual.PromptContractID, expected.PromptContractID)
	}
	if actual.PromptTokenCount != expected.PromptTokenCount {
		return fmt.Sprintf(
			"prompt tokens = %d, want %d", actual.PromptTokenCount, expected.PromptTokenCount)
	}
	if len(actual.BlockBoundaries) != len(expected.BlockBoundaries) {
		return fmt.Sprintf(
			"block boundaries = %d, want %d", len(actual.BlockBoundaries), len(expected.BlockBoundaries))
	}
	for index := range expected.BlockBoundaries {
		if actual.BlockBoundaries[index] != expected.BlockBoundaries[index] {
			return fmt.Sprintf("block boundary %d differs", index)
		}
	}
	if !equalOptionalString(actual.LastCompleteBlockHash, expected.LastCompleteBlockHash) {
		return "last complete block hash differs"
	}
	return ""
}

func equalOptionalString(left, right *string) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func appendFailure(report *loadReport, failure string) {
	if len(report.FailureSamples) < maxFailureSamples {
		report.FailureSamples = append(report.FailureSamples, failure)
	}
}
