package analyticssnapshot

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func setUsageBucket(s *Snapshot, name string, minute time.Time, requests, prompt, completion int64) {
	series := s.Series[name]
	series.Buckets = append(series.Buckets, store.UsageBucket{
		Minute: minute, Requests: requests, PromptTokens: prompt, CompletionTokens: completion,
	})
	s.Series[name] = series
}

func TestSeriesAllowsSignedTokenCorrectionsAtAlignedBoundaries(t *testing.T) {
	now := time.Date(2026, 9, 29, 12, 1, 0, 0, time.UTC)
	s := fixture(now)
	setUsageBucket(s, "30m", s.Series["30m"].End.Add(-time.Minute), 0, -3, -5)
	setUsageBucket(s, "24h", s.Series["24h"].End.Add(-30*time.Minute), 0, -3, -5)
	setUsageBucket(s, "7d", s.Series["7d"].End.Add(-4*time.Hour), 0, -3, -5)
	setUsageBucket(s, "30d", s.Series["30d"].End.Add(-12*time.Hour), 0, -3, -5)
	if err := s.validateSeries(); err != nil {
		t.Fatal(err)
	}
}

func TestSeriesRejectsContradictoryOverlapsIncludingOmittedBuckets(t *testing.T) {
	now := time.Date(2026, 9, 29, 12, 1, 0, 0, time.UTC)
	for _, tc := range []struct {
		name    string
		fine    string
		coarse  string
		step    time.Duration
		request int64
		prompt  int64
	}{
		{"requests", "24h", "7d", 30 * time.Minute, 10, 0},
		{"signed_tokens", "30m", "24h", time.Minute, 0, -2},
		{"omitted_coarse", "7d", "30d", 4 * time.Hour, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := fixture(now)
			fine := s.Series[tc.fine]
			setUsageBucket(s, tc.fine, fine.End.Add(-tc.step), tc.request, tc.prompt, 0)
			if err := s.validateSeries(); err == nil {
				t.Fatal("accepted contradictory overlapping usage series")
			}
		})
	}
}

func TestSeriesDoesNotComparePartialCoarseInterval(t *testing.T) {
	now := time.Date(2026, 9, 29, 12, 16, 0, 0, time.UTC)
	s := fixture(now)
	setUsageBucket(s, "30m", s.Series["30m"].End.Add(time.Minute*-1), 1, -2, 3)
	if err := s.validateSeries(); err != nil {
		t.Fatal(err)
	}
}
