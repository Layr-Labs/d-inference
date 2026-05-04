package e2e

import (
	"context"
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

	ctx := context.Background()
	s := testbed.NewSuite(suiteCfg)
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)

	t.Logf("[%s] %d providers (%v), %d users, models=%v, requests=%d, concurrency=%d, streaming=%v",
		name, suiteCfg.TotalProviders(), suiteCfg.ModelSpecs, suiteCfg.NumUsers, suiteCfg.AllModelIDs(),
		reqCfg.TotalRequests, reqCfg.Concurrency, reqCfg.Streaming)

	lg := testbed.NewLoadGenerator(s, reqCfg)
	result := lg.Run()

	t.Logf("\n%s", result.SummaryTable())

	t.Logf("\nPer-model breakdown:")
	modelStats := make(map[string]*modelResult)
	for _, rr := range result.RequestResults {
		st, ok := modelStats[rr.ModelID]
		if !ok {
			st = &modelResult{modelID: rr.ModelID}
			modelStats[rr.ModelID] = st
		}
		st.count++
		if rr.StatusCode == 200 {
			st.success++
			st.totalDuration += rr.Duration
			if st.minDuration == 0 || rr.Duration < st.minDuration {
				st.minDuration = rr.Duration
			}
			if rr.Duration > st.maxDuration {
				st.maxDuration = rr.Duration
			}
		} else {
			st.errors++
		}
	}
	for _, st := range modelStats {
		var avg time.Duration
		if st.success > 0 {
			avg = st.totalDuration / time.Duration(st.success)
		}
		t.Logf("  %-45s total=%d success=%d errors=%d avg=%s min=%s max=%s",
			st.modelID, st.count, st.success, st.errors,
			avg.Round(time.Millisecond),
			st.minDuration.Round(time.Millisecond),
			st.maxDuration.Round(time.Millisecond))
	}

	t.Logf("\nPer-user breakdown:")
	userStats := make(map[int]*userResult)
	for _, rr := range result.RequestResults {
		st, ok := userStats[rr.UserIndex]
		if !ok {
			st = &userResult{userIndex: rr.UserIndex}
			userStats[rr.UserIndex] = st
		}
		st.count++
		if rr.StatusCode == 200 {
			st.success++
		} else {
			st.errors++
		}
	}
	for i := 0; i < suiteCfg.NumUsers; i++ {
		st := userStats[i]
		if st == nil {
			t.Logf("  user-%d: no requests", i)
			continue
		}
		t.Logf("  user-%d: total=%d success=%d errors=%d", i, st.count, st.success, st.errors)
	}

	require.Greater(t, result.SuccessCount, 0, "at least some requests should succeed")

	assertReport := tbassert.NewAsserter(tbassert.CoordinatorOverheadThresholds()).Evaluate(result.SegmentStatsMap())
	t.Logf("\n%s", assertReport.SummaryTable())
	for _, r := range assertReport.Results {
		if !r.Passed {
			t.Logf("WARNING: %s — %s", r.Name, r.Message)
		}
	}

	benchmarkMarkdownMu.Lock()
	benchmarkMarkdown.WriteString(fmt.Sprintf("## %s\n\n", name))
	benchmarkMarkdown.WriteString(fmt.Sprintf("%d providers, %d users, %d requests, concurrency=%d, streaming=%v\n\n",
		suiteCfg.TotalProviders(), suiteCfg.NumUsers, reqCfg.TotalRequests, reqCfg.Concurrency, reqCfg.Streaming))
	benchmarkMarkdown.WriteString("| Model | Providers | RAM |\n|---|---|---|\n")
	for _, spec := range suiteCfg.ModelSpecs {
		ram, ok := testbed.KnownModelSizes[spec.ModelID]
		if !ok {
			ram = "unknown"
		}
		benchmarkMarkdown.WriteString(fmt.Sprintf("| %s | %d | %s |\n", spec.ModelID, spec.NumProviders, ram))
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
			_ = os.WriteFile(outPath, []byte(md), 0644)
		}
	}

	os.Exit(code)
}

func TestBenchmark_SingleProviderStreaming(t *testing.T) {
	runBenchmark(t, "1-provider-streaming",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 1}},
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
			ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 1}},
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
			ModelSpecs: []testbed.ModelSpec{
				{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 4},
				{ModelID: "mlx-community/gemma-3-270m-4bit", NumProviders: 3},
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
			ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 3}},
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

func TestBenchmark_QueueSaturation(t *testing.T) {
	runBenchmark(t, "1-provider-queue-saturation",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 1}},
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
			ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 3}},
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
					ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: numProviders}},
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
			ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 3}},
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

type modelResult struct {
	modelID       string
	count         int
	success       int
	errors        int
	totalDuration time.Duration
	minDuration   time.Duration
	maxDuration   time.Duration
}

type userResult struct {
	userIndex int
	count     int
	success   int
	errors    int
}
