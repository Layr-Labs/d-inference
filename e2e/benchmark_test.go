package e2e

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

func TestBenchmark_MultiModelMultiProvider(t *testing.T) {
	cfg := testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{
			{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 4},
			{ModelID: "mlx-community/gemma-3-270m-4bit", NumProviders: 3},
		},
		NumUsers:      5,
		QueueCapacity: 200,
		QueueTimeout:  120 * time.Second,
		SeedBalance:   500_000_000,
	}

	ctx := context.Background()
	s := testbed.NewSuite(cfg)
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)

	t.Logf("Suite: %d providers (%v), %d users, models=%v",
		cfg.TotalProviders(), cfg.ModelSpecs, cfg.NumUsers, cfg.AllModelIDs())

	lg := testbed.NewLoadGenerator(s, testbed.RequestConfig{
		Streaming:     true,
		TotalRequests: 50,
		Concurrency:   10,
		MaxTokens:     64,
		Temperature:   0.0,
	})

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
	for i := 0; i < cfg.NumUsers; i++ {
		st := userStats[i]
		if st == nil {
			t.Logf("  user-%d: no requests", i)
			continue
		}
		t.Logf("  user-%d: total=%d success=%d errors=%d", i, st.count, st.success, st.errors)
	}

	require.Greater(t, result.SuccessCount, 0, "at least some requests should succeed")
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
