package registry

import (
	"context"
	"math"
	"testing"
	"time"
)

func TestEWMAFirstValue(t *testing.T) {
	e := newEWMA(10 * time.Second)
	want := 5.0
	e.add(want)
	if got := e.valuePerSecond(); math.Abs(got-want) > 1e-9 {
		t.Fatalf("first ewma value = %v, want %v", got, want)
	}
}

func TestEWMAMixesSubsequentValues(t *testing.T) {
	tc := 10 * time.Second
	e := newEWMA(tc)
	alpha := 1 - math.Exp(-1.0/tc.Seconds())

	e.add(10.0)
	e.add(20.0)
	want := alpha*20.0 + (1-alpha)*10.0
	if got := e.valuePerSecond(); math.Abs(got-want) > 1e-9 {
		t.Fatalf("ewma value = %v, want %v", got, want)
	}
}

func TestEWMAConvergesToMean(t *testing.T) {
	e := newEWMA(10 * time.Second)
	for range 100 {
		e.add(42.0)
	}
	if got := e.valuePerSecond(); math.Abs(got-42.0) > 1e-6 {
		t.Fatalf("ewma value = %v, want ~42", got)
	}
}

func TestRecordRequestUpdatesForecast(t *testing.T) {
	f := NewDemandForecaster(nil, DefaultWarmingConfig())
	model := "request-signal-model"

	// Record requests at a steady ~10 rps so the short-term EWMAs populate.
	for range 15 {
		f.RecordRequest(model)
		time.Sleep(100 * time.Millisecond)
	}

	forecast := f.Forecast(context.Background(), model)
	if forecast.RecentRPS <= 0 {
		t.Fatalf("RecentRPS = %v, want > 0", forecast.RecentRPS)
	}
	if forecast.Confidence < 0.7 {
		t.Fatalf("Confidence = %v, want >= 0.7 after recent requests", forecast.Confidence)
	}
	if forecast.RequestsPerSecond <= 0 {
		t.Fatalf("RequestsPerSecond = %v, want > 0", forecast.RequestsPerSecond)
	}
}

func TestRecordQueueUpdatesForecast(t *testing.T) {
	f := NewDemandForecaster(nil, DefaultWarmingConfig())
	model := "queue-signal-model"
	depth := 9

	f.RecordQueue(model, depth)
	forecast := f.Forecast(context.Background(), model)

	wantQueuedRPS := float64(depth) / 3.0
	if math.Abs(forecast.QueuedRPS-wantQueuedRPS) > 1e-9 {
		t.Fatalf("QueuedRPS = %v, want %v", forecast.QueuedRPS, wantQueuedRPS)
	}
	if forecast.RequestsPerSecond != forecast.QueuedRPS {
		t.Fatalf("RequestsPerSecond = %v, want %v (queue is the only signal)", forecast.RequestsPerSecond, forecast.QueuedRPS)
	}
}

func TestForecastConfidenceScenarios(t *testing.T) {
	cfg := DefaultWarmingConfig()
	f := NewDemandForecaster(nil, cfg)

	tests := []struct {
		name       string
		requests   bool
		queueDepth int
		wantConf   float64
		wantRPSPos bool
	}{
		{"no signal", false, 0, 0.3, false},
		{"recent only", true, 0, 0.7, true},
		{"queue only", false, 6, 0.6, true},
		{"recent + queue", true, 6, 1.0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			model := "conf-" + tt.name
			if tt.requests {
				f.RecordRequest(model)
				f.RecordRequest(model)
			}
			if tt.queueDepth > 0 {
				f.RecordQueue(model, tt.queueDepth)
			}

			forecast := f.Forecast(context.Background(), model)
			if math.Abs(forecast.Confidence-tt.wantConf) > 1e-9 {
				t.Fatalf("Confidence = %v, want %v", forecast.Confidence, tt.wantConf)
			}
			if tt.wantRPSPos && forecast.RequestsPerSecond <= 0 {
				t.Fatalf("RequestsPerSecond = %v, want > 0", forecast.RequestsPerSecond)
			}
			if !tt.wantRPSPos && forecast.RequestsPerSecond != 0 {
				t.Fatalf("RequestsPerSecond = %v, want 0", forecast.RequestsPerSecond)
			}
		})
	}
}

func TestForecastWithHistoricalBaseline(t *testing.T) {
	hist := &constantHistoricalSource{rps: 5.0}
	cfg := DefaultWarmingConfig()
	f := NewDemandForecaster(hist, cfg)
	model := "historical-model"

	forecast := f.Forecast(context.Background(), model)
	if forecast.HistoricalRPS != 5.0 {
		t.Fatalf("HistoricalRPS = %v, want 5.0", forecast.HistoricalRPS)
	}
	if math.Abs(forecast.Confidence-0.3) > 1e-9 {
		t.Fatalf("Confidence = %v, want 0.3 for historical-only signal", forecast.Confidence)
	}
	// With no recent/queued signal, the score is the discounted historical weight.
	// histWeight = HistoricalWeight * (1 - confidence*0.5) = 0.5 * 0.85 = 0.425.
	want := 0.425 * 5.0
	if math.Abs(forecast.RequestsPerSecond-want) > 1e-9 {
		t.Fatalf("RequestsPerSecond = %v, want %v", forecast.RequestsPerSecond, want)
	}
}

func TestModelsWithDemand(t *testing.T) {
	f := NewDemandForecaster(nil, DefaultWarmingConfig())
	f.RecordRequest("demand-a")
	f.RecordQueue("demand-b", 3)

	got := f.ModelsWithDemand()
	if len(got) != 2 {
		t.Fatalf("ModelsWithDemand returned %v, want 2 models", got)
	}
	seen := make(map[string]bool)
	for _, m := range got {
		seen[m] = true
	}
	if !seen["demand-a"] || !seen["demand-b"] {
		t.Fatalf("missing expected model in %v", got)
	}
}

type constantHistoricalSource struct {
	rps float64
}

func (c *constantHistoricalSource) HistoricalDemand(context.Context, string, time.Duration) (float64, error) {
	return c.rps, nil
}
