package store

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"
)

func assertModelDemandPublishedSums(t *testing.T, models []ModelDemandCounts) {
	t.Helper()
	for _, model := range models {
		var sum DemandOutcomeCounts
		for _, bucket := range model.TimeSeries {
			if bucket.Counts == nil {
				continue
			}
			c := bucket.Counts
			sum.Requests += c.Requests
			sum.Completed += c.Completed
			sum.CapacityRejected += c.CapacityRejected
			sum.LatencyRejected += c.LatencyRejected
			sum.TimedOut += c.TimedOut
			sum.Failed += c.Failed
			sum.Cancelled += c.Cancelled
			sum.Unknown += c.Unknown
			sum.HTTP429 += c.HTTP429
		}
		if model.DemandOutcomeCounts != sum {
			t.Fatalf("%s: summary %+v exposes a residual beyond published counts %+v", model.Model, model.DemandOutcomeCounts, sum)
		}
	}
}

func modelDemandHiddenHourContract(t *testing.T, s demandTestStore) {
	t.Helper()
	ctx := context.Background()
	end := time.Date(2026, time.September, 25, 13, 0, 0, 0, time.UTC)
	start := end.Add(-24 * time.Hour)
	hiddenHour := end.Add(-time.Hour)
	windows := []int{1, 7, 30}
	read := func(days int) ModelDemandSnapshot {
		t.Helper()
		out, err := s.ModelDemand(ctx, end.Add(-time.Duration(days)*24*time.Hour), end)
		if err != nil {
			t.Fatal(err)
		}
		assertModelDemandPublishedSums(t, out.Models)
		return out
	}
	for _, days := range windows {
		if out := read(days); len(out.Models) != 0 {
			t.Fatalf("%dd: empty collection published models: %+v", days, out.Models)
		}
	}

	sequence := 0
	record := func(model string, at time.Time, consumer int, outcome string, status int) RequestOutcomeRecord {
		sequence++
		return RequestOutcomeRecord{
			CoordRequestID: fmt.Sprintf("hour-privacy-%d", sequence), SchemaVersion: 1, Revision: 1,
			ReceivedAt: at, UpdatedAt: at, Endpoint: "/v1/messages", HTTPStatus: status,
			PublicDemand: &PublicDemandScope{Model: model, ConsumerHash: HashKey(fmt.Sprint(consumer)), Outcome: outcome},
		}
	}
	outcomes := []string{"completed", "capacity_rejected", "latency_rejected", "timed_out", "failed", "cancelled", "unknown"}
	var visible []RequestOutcomeRecord
	// All but one UTC hour are publishable, so whole-window totals would reveal
	// the remaining gap exactly by subtracting the visible intervals.
	for hour := range 23 {
		for i := range 20 {
			status := 200
			if i%7 >= 1 && i%7 <= 3 {
				status = 429
			}
			at := start.Add(time.Duration(hour)*time.Hour + time.Minute + time.Duration(i)*time.Second)
			visible = append(visible, record("dense-model", at, i%3, outcomes[i%7], status))
		}
	}
	// Equal published counts sort by model ID, even when private demand differs.
	for _, model := range []string{"z-model", "a-model"} {
		for i := range 20 {
			visible = append(visible, record(model, start.Add(time.Minute), i%3, "completed", 200))
		}
	}
	if err := s.RecordRequestOutcomes(ctx, visible); err != nil {
		t.Fatal(err)
	}
	baseline := make(map[int][]ModelDemandCounts, len(windows))
	wantDense := DemandOutcomeCounts{Requests: 460, Completed: 69, CapacityRejected: 69, LatencyRejected: 69, TimedOut: 69, Failed: 69, Cancelled: 69, Unknown: 46, HTTP429: 207}
	for _, days := range windows {
		out := read(days)
		if len(out.Models) != 3 || out.Models[0].Model != "dense-model" || out.Models[1].Model != "a-model" || out.Models[2].Model != "z-model" {
			t.Fatalf("%dd: published ordering: %+v", days, out.Models)
		}
		if out.Models[0].DemandOutcomeCounts != wantDense {
			t.Fatalf("%dd: published partition: %+v, want %+v", days, out.Models[0], wantDense)
		}
		baseline[days] = out.Models
	}
	series := baseline[1][0].TimeSeries
	if len(series) != 24 {
		t.Fatalf("hourly series length: %d", len(series))
	}
	for i, bucket := range series {
		if !bucket.Timestamp.Equal(start.Add(time.Duration(i) * time.Hour)) {
			t.Fatalf("hour %d: unexpected timestamp %v", i, bucket.Timestamp)
		}
		if i == 23 {
			if bucket.Counts != nil {
				t.Fatalf("unobserved hour should be null: %+v", bucket)
			}
		} else if bucket.Counts == nil || bucket.Counts.Requests != 20 {
			t.Fatalf("published hour %d: %+v", i, bucket)
		}
	}
	// Coarse intervals contain only their eligible constituent hours.
	for _, tc := range []struct {
		days     int
		requests int64
	}{{7, 100}, {30, 460}} {
		buckets := baseline[tc.days][0].TimeSeries
		last := buckets[len(buckets)-1].Counts
		if last == nil || last.Requests != tc.requests {
			t.Fatalf("%dd: partial coarse interval: %+v", tc.days, last)
		}
	}
	unchanged := func(stage string) {
		t.Helper()
		for _, days := range windows {
			if got := read(days).Models; !reflect.DeepEqual(got, baseline[days]) {
				t.Fatalf("%s, %dd: ineligible hours changed public models\ngot: %+v\nwant: %+v", stage, days, got, baseline[days])
			}
		}
	}
	var hidden []RequestOutcomeRecord
	for i := range 19 {
		hidden = append(hidden, record("dense-model", hiddenHour.Add(time.Minute), i%3, "capacity_rejected", 429))
	}
	// This hour easily passes the request floor but not the consumer floor.
	for i := range 480 {
		hidden = append(hidden, record("z-model", hiddenHour.Add(time.Minute), i%2, "latency_rejected", 429))
	}
	// No individual hour qualifies, even though this model's window does.
	for i := range 24 {
		at := hiddenHour.Add(-time.Duration(i/12)*time.Hour + time.Minute)
		hidden = append(hidden, record("hidden-only", at, i%3, "failed", 500))
	}
	if err := s.RecordRequestOutcomes(ctx, hidden); err != nil {
		t.Fatal(err)
	}
	unchanged("hidden arrivals")

	// Excluded records cannot satisfy either floor or change published counts,
	// including diagnostic 429s and otherwise-new consumers.
	excluded := []RequestOutcomeRecord{
		record("dense-model", hiddenHour.Add(time.Minute), 3, "excluded", 429),
		record("z-model", hiddenHour.Add(time.Minute), 2, "excluded", 429),
		record("dense-model", start.Add(time.Minute), 3, "excluded", 429),
	}
	if err := s.RecordRequestOutcomes(ctx, excluded); err != nil {
		t.Fatal(err)
	}
	unchanged("excluded arrivals")

	// Late, duplicate and stale hidden evidence must remain unobservable.
	late := cloneRequestOutcome(hidden[0])
	late.Revision++
	late.PublicDemand.Outcome = "completed"
	late.HTTPStatus = 200
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{late, late, hidden[0]}); err != nil {
		t.Fatal(err)
	}
	unchanged("late and replayed hidden revisions")
	conflict := cloneRequestOutcome(late)
	conflict.PublicDemand.Outcome = "failed"
	if err := s.RecordRequestOutcomes(ctx, []RequestOutcomeRecord{conflict}); err != nil {
		t.Fatal(err)
	}
	unchanged("conflicting hidden revision")
}

func TestModelDemandHiddenHourMemory(t *testing.T) {
	modelDemandHiddenHourContract(t, NewMemory(Config{}))
}

func TestModelDemandHiddenHourPostgres(t *testing.T) {
	modelDemandHiddenHourContract(t, testPostgresStore(t))
}
