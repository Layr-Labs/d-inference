package e2e

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	tbassert "github.com/eigeninference/d-inference/e2e/testbed/assert"
)

var (
	benchmarkMarkdownMu sync.Mutex
	benchmarkMarkdown   strings.Builder
)

const benchmarkMinimumSuccessPercent = 90

func init() {
	benchmarkMarkdown.WriteString("# Benchmark Results\n\n")
	benchmarkMarkdown.WriteString(fmt.Sprintf("Runner: `%s` | Date: %s\n\n",
		envOr("RUNNER_DESC", "local"),
		time.Now().UTC().Format("2006-01-02 15:04 UTC")))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func runBenchmark(t *testing.T, name string, suiteCfg testbed.SuiteConfig, reqCfg testbed.RequestConfig) {
	t.Helper()

	reqCfg.ExpectedSuccesses = reqCfg.TotalRequests
	reqCfg.MinimumSuccesses = minimumBenchmarkSuccesses(reqCfg.TotalRequests)
	s := testbed.StartSuite(t, suiteCfg)

	t.Logf("[%s] %d providers (%v), %d users, models=%v, requests=%d, concurrency=%d, streaming=%v",
		name, suiteCfg.TotalProviders(), suiteCfg.ModelSpecs, suiteCfg.NumUsers, suiteCfg.AllModelIDs(),
		reqCfg.TotalRequests, reqCfg.Concurrency, reqCfg.Streaming)

	result, loadErr := testbed.NewLoadGenerator(s, reqCfg).Run()
	require.NotNil(t, result, "load generator must return its measurements")
	t.Logf("\n%s", result.SummaryTable())
	for i, failure := range result.Failures {
		require.Errorf(t, failure.Err, "failed request %d must retain its exact error", failure.Index)
		if i < 5 {
			t.Logf("request failure: %s", failure.Error())
		}
	}
	require.NoError(t, loadErr, "benchmark workload failed its overall success threshold")

	require.Equal(t, reqCfg.TotalRequests, result.TotalRequests,
		"load result must preserve the configured workload size")
	require.Len(t, result.RequestResults, reqCfg.TotalRequests,
		"load generator must account for every request")
	require.Equal(t, result.TotalRequests, result.SuccessCount+result.ErrorCount,
		"success and error counts must account for the full workload")
	require.Len(t, result.Failures, result.ErrorCount,
		"every failed request must retain its exact error")
	require.Equal(t, reqCfg.ExpectedSuccesses, result.ExpectedSuccesses)
	require.Equal(t, reqCfg.MinimumSuccesses, result.MinimumSuccesses)
	requireSuccessRatio(t, "overall workload", result.SuccessCount, result.TotalRequests)

	t.Logf("\nPer-model breakdown:")
	for _, modelID := range suiteCfg.AllModelIDs() {
		stats, ok := result.ModelCohorts[modelID]
		require.Truef(t, ok, "configured model %q received no requests", modelID)
		t.Logf("  %-45s total=%d success=%d errors=%d",
			modelID, stats.TotalRequests, stats.SuccessCount, stats.ErrorCount)
		require.Equal(t, stats.TotalRequests, stats.SuccessCount+stats.ErrorCount,
			"model cohort %q has incomplete accounting", modelID)
		require.Len(t, stats.Failures, stats.ErrorCount,
			"model cohort %q must retain every error", modelID)
		requireSuccessRatio(t, "model "+modelID, stats.SuccessCount, stats.TotalRequests)
	}

	t.Logf("\nPer-user breakdown:")
	for userIndex := range suiteCfg.NumUsers {
		stats, ok := result.UserCohorts[userIndex]
		require.Truef(t, ok, "configured user-%d received no requests", userIndex)
		t.Logf("  user-%d: total=%d success=%d errors=%d",
			userIndex, stats.TotalRequests, stats.SuccessCount, stats.ErrorCount)
		require.Equal(t, stats.TotalRequests, stats.SuccessCount+stats.ErrorCount,
			"user-%d cohort has incomplete accounting", userIndex)
		require.Len(t, stats.Failures, stats.ErrorCount,
			"user-%d cohort must retain every error", userIndex)
		requireSuccessRatio(t, fmt.Sprintf("user-%d", userIndex), stats.SuccessCount, stats.TotalRequests)
	}

	if reqCfg.Streaming {
		require.NotNil(t, result.ProfileRun, "streaming workload must report TTFT metrics")
		require.Len(t, result.ProfileRun.TTFTs, result.SuccessCount,
			"every successful streaming request must report TTFT")
		for i, ttft := range result.ProfileRun.TTFTs {
			require.Positivef(t, ttft, "TTFT sample %d must be positive", i)
		}
		for _, request := range result.RequestResults {
			if request.Error == nil && request.StatusCode == 200 {
				require.Positivef(t, request.TTFT,
					"successful streaming request %d must record TTFT", request.Index)
			}
		}
	}

	assertReport := tbassert.NewAsserter(tbassert.CoordinatorOverheadThresholds()).Evaluate(result.SegmentStatsMap())
	t.Logf("\n%s", assertReport.SummaryTable())
	for _, assertion := range assertReport.Results {
		if !assertion.Passed {
			t.Logf("FAILED: %s — %s", assertion.Name, assertion.Message)
		}
	}
	require.True(t, assertReport.Passed, "coordinator overhead thresholds failed")

	benchmarkMarkdownMu.Lock()
	benchmarkMarkdown.WriteString(fmt.Sprintf("## %s\n\n", name))
	benchmarkMarkdown.WriteString(fmt.Sprintf("%d providers, %d users, %d requests, concurrency=%d, streaming=%v\n\n",
		suiteCfg.TotalProviders(), suiteCfg.NumUsers, reqCfg.TotalRequests, reqCfg.Concurrency, reqCfg.Streaming))
	benchmarkMarkdown.WriteString("| Model | Providers | RAM |\n|---|---|---|\n")
	for _, spec := range suiteCfg.ModelSpecs {
		for _, modelID := range spec.IDs() {
			ram, ok := testbed.KnownModelSizes[modelID]
			if !ok {
				ram = "unknown"
			}
			benchmarkMarkdown.WriteString(fmt.Sprintf("| %s | %d | %s |\n", modelID, spec.NumProviders, ram))
		}
	}
	benchmarkMarkdown.WriteString("\n")
	benchmarkMarkdown.WriteString(result.SummaryMarkdown())
	benchmarkMarkdown.WriteString("\n")
	benchmarkMarkdown.WriteString(assertReport.SummaryMarkdown())
	benchmarkMarkdown.WriteString("\n\n")
	benchmarkMarkdownMu.Unlock()
}

func TestMain(m *testing.M) {
	code := m.Run()

	if code == 0 {
		benchmarkMarkdownMu.Lock()
		md := benchmarkMarkdown.String()
		benchmarkMarkdownMu.Unlock()

		if outPath := os.Getenv("BENCHMARK_MD_PATH"); outPath != "" && md != "" {
			if err := os.WriteFile(outPath, []byte(md), 0o644); err != nil {
				fmt.Fprintf(os.Stderr, "write benchmark results to %q: %v\n", outPath, err)
				code = 1
			}
		}
	}

	os.Exit(code)
}

func TestBenchmark_SingleProviderStreaming(t *testing.T) {
	runBenchmark(t, "1-provider-streaming",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 1}},
			NumUsers:      1,
			QueueCapacity: 100,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 30,
			Concurrency:   5,
			MaxTokens:     64,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_SingleProviderNonStreaming(t *testing.T) {
	runBenchmark(t, "1-provider-non-streaming",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 1}},
			NumUsers:      1,
			QueueCapacity: 100,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     false,
			TotalRequests: 20,
			Concurrency:   5,
			MaxTokens:     64,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_MultiModelMultiProvider(t *testing.T) {
	runBenchmark(t, "7-provider-multi-model",
		testbed.SuiteConfig{
			// Both models must be CBv2-servable (v0.7.5 one-engine) — a
			// non-CBv2 checkpoint never registers, so its share of the
			// round-robin would only measure routing failures.
			ModelSpecs: []testbed.ModelSpec{
				{ModelID: testbed.DefaultTestModelID(), NumProviders: 4},
				{ModelID: testbed.SecondaryTestModelID(), NumProviders: 3},
			},
			NumUsers:      5,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 50,
			Concurrency:   10,
			MaxTokens:     64,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_HighConcurrency(t *testing.T) {
	runBenchmark(t, "3-provider-high-concurrency",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 3}},
			NumUsers:      10,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 60,
			Concurrency:   20,
			MaxTokens:     32,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_ProviderCapacityPressure(t *testing.T) {
	runBenchmark(t, "1-provider-capacity-pressure",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 1}},
			NumUsers:      10,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 40,
			Concurrency:   15,
			MaxTokens:     32,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_ManyUsers(t *testing.T) {
	runBenchmark(t, "3-provider-20-users",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 3}},
			NumUsers:      20,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 60,
			Concurrency:   10,
			MaxTokens:     32,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_SingleModelScaling(t *testing.T) {
	for _, numProviders := range []int{1, 3, 5} {
		t.Run(fmt.Sprintf("%d-providers", numProviders), func(t *testing.T) {
			runBenchmark(t, fmt.Sprintf("%d-provider-scaling", numProviders),
				testbed.SuiteConfig{
					ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: numProviders}},
					NumUsers:      5,
					QueueCapacity: 200,
					QueueTimeout:  120 * time.Second,
					SeedBalance:   500_000_000,
				},
				testbed.RequestConfig{
					Streaming:     true,
					TotalRequests: 30,
					Concurrency:   10,
					MaxTokens:     32,
					Temperature:   0.0,
				},
			)
		})
	}
}

func TestBenchmark_HeavyLoad_100Concurrent_10KB(t *testing.T) {
	runBenchmark(t, "3-provider-heavy-100conc-10kb",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 3}},
			NumUsers:      20,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   2_000_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 100,
			Concurrency:   100,
			MaxTokens:     32,
			Temperature:   0.0,
			PromptBytes:   10 * 1024,
		},
	)
}

func minimumBenchmarkSuccesses(requests int) int {
	return (requests*benchmarkMinimumSuccessPercent + 99) / 100
}

func requireSuccessRatio(t *testing.T, cohort string, successes, requests int) {
	t.Helper()
	require.Positivef(t, requests, "%s received no requests", cohort)
	require.GreaterOrEqualf(t, successes*100, requests*benchmarkMinimumSuccessPercent,
		"%s success ratio %.1f%% is below %d%% (%d/%d)",
		cohort, float64(successes)*100/float64(requests),
		benchmarkMinimumSuccessPercent, successes, requests)
}
