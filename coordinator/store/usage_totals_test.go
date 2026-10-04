package store

import (
	"testing"
	"time"
)

// TestUsageTotalsAndSeriesBackends checks the lifetime and windowed usage
// aggregates on both backends. The Postgres harness truncates the usage
// table, but lifetime totals live in a counter row that survives it, so the
// lifetime check compares before and after.
func TestUsageTotalsAndSeriesBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			before, err := s.UsageTotals()
			if err != nil {
				t.Fatalf("UsageTotals before: %v", err)
			}
			start := time.Now().Add(-time.Second)
			for i, tokens := range [][2]int{{100, 10}, {50, 5}, {7, 3}} {
				s.RecordUsage(UsageRecord{
					ProviderID: "prov", ConsumerKey: uniqueID("consumer"), Model: "model",
					RequestID: uniqueID("req"), PromptTokens: tokens[0], CompletionTokens: tokens[1],
					CostMicroUSD: int64(i + 1),
				})
			}

			total, err := s.UsageTotals()
			if err != nil {
				t.Fatalf("UsageTotals: %v", err)
			}
			want := UsageTotals{Requests: 3, PromptTokens: 157, CompletionTokens: 18}
			delta := UsageTotals{
				Requests:         total.Requests - before.Requests,
				PromptTokens:     total.PromptTokens - before.PromptTokens,
				CompletionTokens: total.CompletionTokens - before.CompletionTokens,
			}
			if delta != want {
				t.Fatalf("lifetime totals grew by %+v, want %+v", delta, want)
			}
			since, err := s.UsageTotalsSince(start)
			if err != nil || since != want {
				t.Fatalf("totals since start = %+v, %v; want %+v", since, err, want)
			}
			future := time.Now().Add(time.Hour)
			if empty, err := s.UsageTotalsSince(future); err != nil || empty.Requests != 0 || empty.PromptTokens != 0 {
				t.Fatalf("totals since the future = %+v, %v", empty, err)
			}

			if n, err := s.UsageCountSince(start); err != nil || n != 3 {
				t.Fatalf("UsageCountSince(start) = %d, %v", n, err)
			}
			if n, err := s.UsageCountSince(time.Time{}); err != nil || n != 3 {
				t.Fatalf("UsageCountSince(zero) = %d, %v", n, err)
			}
			if n, err := s.UsageCountSince(future); err != nil || n != 0 {
				t.Fatalf("UsageCountSince(future) = %d, %v", n, err)
			}

			buckets, err := s.UsageTimeSeries(time.Now().Add(-time.Hour), time.Now().Add(time.Minute), time.Minute)
			if err != nil {
				t.Fatalf("UsageTimeSeries: %v", err)
			}
			var requests, prompt, completion int64
			for _, b := range buckets {
				requests += b.Requests
				prompt += b.PromptTokens
				completion += b.CompletionTokens
			}
			if requests != 3 || prompt != 157 || completion != 18 {
				t.Fatalf("time series sums = %d requests, %d prompt, %d completion", requests, prompt, completion)
			}
		})
	}
}
