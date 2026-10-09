package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
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
				s.RecordUsage(store.UsageRecord{
					ProviderID: "prov", ConsumerKey: uniqueID("consumer"), Model: "model",
					RequestID: uniqueID("req"), PromptTokens: tokens[0], CompletionTokens: tokens[1],
					CostMicroUSD: int64(i + 1),
				})
			}

			total, err := s.UsageTotals()
			if err != nil {
				t.Fatalf("UsageTotals: %v", err)
			}
			want := store.UsageTotals{Requests: 3, PromptTokens: 157, CompletionTokens: 18}
			delta := store.UsageTotals{
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

			records := s.UsageRecords()
			if len(records) != 3 {
				t.Fatalf("usage records = %d, want 3", len(records))
			}
			until := records[0].Timestamp
			for _, record := range records[1:] {
				if record.Timestamp.After(until) {
					until = record.Timestamp
				}
			}
			// The upper bound is exclusive and future bounds are clamped to now.
			// Advance past the stored timestamps at PostgreSQL's microsecond precision.
			until = until.Add(time.Microsecond)
			deadline := time.Now().Add(time.Second)
			for !time.Now().After(until) {
				if time.Now().After(deadline) {
					t.Fatalf("clock did not advance past usage upper bound %s", until)
				}
				time.Sleep(time.Microsecond)
			}
			buckets, err := s.UsageTimeSeries(start, until, time.Minute)
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
