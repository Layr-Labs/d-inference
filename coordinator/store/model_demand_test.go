package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

type demandTestStore interface {
	RequestOutcomeStore
	ModelDemandStore
	PruneTelemetry(context.Context, time.Time, time.Time, int) (int, error)
}

func modelDemandContract(t *testing.T, s demandTestStore) {
	t.Helper()
	ctx := context.Background()
	end := time.Now().UTC().Truncate(time.Hour)
	start := end.Add(-30 * 24 * time.Hour)
	rows := []RequestOutcomeRecord{}
	outcomes := []string{"completed", "capacity_rejected", "latency_rejected", "timed_out", "failed", "cancelled", "unknown"}
	for i := 0; i < 28; i++ {
		status := 200
		if i%7 == 1 || i%7 == 2 || i%7 == 3 {
			status = 429
		}
		rows = append(rows, RequestOutcomeRecord{
			CoordRequestID: fmt.Sprintf("demand-%d", i), SchemaVersion: 1, Revision: 1,
			ReceivedAt: start.Add(time.Hour), UpdatedAt: start.Add(time.Hour), Endpoint: "/v1/messages", HTTPStatus: status,
			PublicDemand: &PublicDemandScope{Model: "public-alias", ConsumerHash: HashKey(fmt.Sprint(i % 3)), Outcome: outcomes[i%7]},
		})
	}
	// Boundary, excluded, sparse, and single-gateway cohorts must not leak.
	for _, name := range []string{"at-end", "before-start", "excluded", "single-consumer", "sparse", "legacy"} {
		count := 30
		if name == "sparse" {
			count = 19
		}
		for i := 0; i < count; i++ {
			r := rows[i%len(rows)]
			r.CoordRequestID = fmt.Sprintf("%s-%d", name, i)
			d := *r.PublicDemand
			d.Model = name
			r.PublicDemand = &d
			switch name {
			case "at-end":
				r.ReceivedAt = end
			case "before-start":
				r.ReceivedAt = start.Add(-time.Second)
			case "excluded":
				d.Outcome = "excluded"
			case "single-consumer":
				d.ConsumerHash = HashKey("gateway")
			case "legacy":
				r.PublicDemand = nil
			}
			rows = append(rows, r)
		}
	}
	if err := s.RecordRequestOutcomes(ctx, rows); err != nil {
		t.Fatal(err)
	}
	get := func() ModelDemandCounts {
		t.Helper()
		v, err := s.ModelDemand(ctx, start, end)
		if err != nil {
			t.Fatal(err)
		}
		if v.CollectionStartedAt.IsZero() || len(v.Models) != 1 {
			t.Fatalf("privacy or coverage: %+v", v)
		}
		assertModelDemandPublishedSums(t, v.Models)
		return v.Models[0]
	}
	c := get()
	if len(c.TimeSeries) != 30 || c.TimeSeries[0].Counts == nil || c.TimeSeries[0].Counts.Requests != 28 || c.TimeSeries[1].Counts != nil {
		t.Fatalf("series coverage: %+v", c.TimeSeries)
	}
	if c.Model != "public-alias" || c.Requests != 28 || c.Completed != 4 || c.CapacityRejected != 4 || c.LatencyRejected != 4 || c.TimedOut != 4 || c.Failed != 4 || c.Cancelled != 4 || c.Unknown != 4 || c.HTTP429 != 12 {
		t.Fatalf("partition: %+v", c)
	}
	// A late terminal changes a bucket without adding a request. Retries and
	// stale snapshots must not count again or regress the terminal.
	late := rows[6]
	late.Revision = 2
	d := *late.PublicDemand
	d.Outcome = "completed"
	late.PublicDemand = &d
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{late, rows[6], late}); err != nil {
		t.Fatal(err)
	}
	c = get()
	if c.Requests != 28 || c.Completed != 5 || c.Unknown != 3 {
		t.Fatalf("late: %+v", c)
	}
	conflict := late
	conflict.HTTPStatus = 500
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{conflict}); err != nil {
		t.Fatal(err)
	}
	c = get()
	if c.Completed != 4 || c.Unknown != 4 {
		t.Fatalf("conflict: %+v", c)
	}
	// Compact evidence outlives 14-day diagnostic retention.
	if _, err := s.PruneTelemetry(ctx, end.Add(-14*24*time.Hour), time.Time{}, 100); err != nil {
		t.Fatal(err)
	}
	if c = get(); c.Requests != 28 {
		t.Fatalf("lost history: %+v", c)
	}
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{rows[6]}); err != nil {
		t.Fatal(err)
	}
	if c = get(); c.Completed != 4 || c.Unknown != 4 {
		t.Fatalf("stale after expiry: %+v", c)
	}
	// 31-day retention does not trim a 30-day window; explicit expiry does.
	if _, err := s.PruneModelDemand(ctx, end.Add(-ModelDemandRetention), 100); err != nil {
		t.Fatal(err)
	}
	if c = get(); c.Requests != 28 {
		t.Fatalf("early expiry: %+v", c)
	}
	if _, err := s.PruneModelDemand(ctx, end, 100); err != nil {
		t.Fatal(err)
	}
	v, err := s.ModelDemand(ctx, start, end)
	if err != nil || len(v.Models) != 0 {
		t.Fatalf("expiry: %+v %v", v, err)
	}
}
func TestModelDemandMemory(t *testing.T)   { modelDemandContract(t, NewMemory(Config{})) }
func TestModelDemandPostgres(t *testing.T) { modelDemandContract(t, testPostgresStore(t)) }

func TestModelDemandCancelledRead(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := NewMemory(Config{}).ModelDemand(ctx, time.Time{}, time.Now()); err == nil {
		t.Fatal("cancelled read succeeded")
	}
}

func modelDemandSeriesPrivacyContract(t *testing.T, s demandTestStore) {
	t.Helper()
	ctx := context.Background()
	end := time.Date(2026, time.September, 25, 13, 0, 0, 0, time.UTC)
	var rows []RequestOutcomeRecord
	for i := 0; i < 24; i++ {
		at := end.Add(-2*time.Hour + time.Duration(i/12)*time.Hour + time.Minute)
		rows = append(rows, RequestOutcomeRecord{CoordRequestID: fmt.Sprintf("interval-%d", i), SchemaVersion: 1, Revision: 1, ReceivedAt: at, UpdatedAt: at, Endpoint: "/v1/messages", HTTPStatus: 429, PublicDemand: &PublicDemandScope{Model: "interval-model", ConsumerHash: HashKey(fmt.Sprint(i % 3)), Outcome: "capacity_rejected"}})
	}
	if err := s.RecordRequestOutcomes(ctx, rows); err != nil {
		t.Fatal(err)
	}
	for _, days := range []int{1, 7, 30} {
		out, err := s.ModelDemand(ctx, end.Add(-time.Duration(days)*24*time.Hour), end)
		if err != nil {
			t.Fatal(err)
		}
		if len(out.Models) != 0 {
			t.Fatalf("%dd: wider buckets restored suppressed hours: %+v", days, out.Models)
		}
	}
	// Reaching exactly 20 requests with three consumers publishes only that hour.
	var added []RequestOutcomeRecord
	for i := 24; i < 32; i++ {
		r := cloneRequestOutcome(rows[i%12])
		r.CoordRequestID = fmt.Sprintf("interval-%d", i)
		added = append(added, r)
	}
	if err := s.RecordRequestOutcomes(ctx, added); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		days, buckets, seconds int
	}{{1, 24, 3600}, {7, 28, 21600}, {30, 30, 86400}} {
		out, err := s.ModelDemand(ctx, end.Add(-time.Duration(tc.days)*24*time.Hour), end)
		if err != nil {
			t.Fatal(err)
		}
		want := DemandOutcomeCounts{Requests: 20, CapacityRejected: 20, HTTP429: 20}
		if len(out.Models) != 1 || out.Models[0].DemandOutcomeCounts != want || out.BucketSeconds != int64(tc.seconds) {
			t.Fatalf("%dd: hourly threshold: %+v", tc.days, out)
		}
		series := out.Models[0].TimeSeries
		if len(series) != tc.buckets {
			t.Fatalf("buckets %d", len(series))
		}
		index := tc.buckets - 1
		if tc.days == 1 {
			index--
		}
		for i, b := range series {
			if i == index {
				if b.Counts == nil || *b.Counts != want {
					t.Fatalf("%dd: eligible interval %+v, want %+v", tc.days, b, want)
				}
			} else if b.Counts != nil {
				t.Fatalf("%dd: suppressed interval became public: %+v", tc.days, b)
			}
		}
	}
	// Removing one request from the cohort suppresses the hour again. Neither
	// an old revision nor an excluded 429 may keep it above the request floor.
	excluded := cloneRequestOutcome(rows[0])
	excluded.Revision++
	excluded.PublicDemand.Outcome = "excluded"
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{excluded, rows[0], excluded}); err != nil {
		t.Fatal(err)
	}
	for _, days := range []int{1, 7, 30} {
		out, err := s.ModelDemand(ctx, end.Add(-time.Duration(days)*24*time.Hour), end)
		if err != nil {
			t.Fatal(err)
		}
		if len(out.Models) != 0 {
			t.Fatalf("%dd: revised cohort below the floor remained public: %+v", days, out.Models)
		}
	}
}
func TestModelDemandSeriesPrivacyMemory(t *testing.T) {
	modelDemandSeriesPrivacyContract(t, NewMemory(Config{}))
}
func TestModelDemandSeriesPrivacyPostgres(t *testing.T) {
	modelDemandSeriesPrivacyContract(t, testPostgresStore(t))
}
