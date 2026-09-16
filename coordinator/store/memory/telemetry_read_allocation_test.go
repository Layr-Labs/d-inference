package memory

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
	"testing"
	"time"
)

func TestMemoryTelemetryReadBuffersAreBounded(t *testing.T) {
	t.Run("routes", func(t *testing.T) {
		s := New(contracts.Config{})
		checkTelemetryReadBuffer(t,
			func(rows []contracts.InferenceRouteRecord) { s.inferenceRoutes = rows },
			s.InferenceRouteRecordsSince,
			func(at time.Time) contracts.InferenceRouteRecord {
				return contracts.InferenceRouteRecord{CreatedAt: at}
			},
			func(row contracts.InferenceRouteRecord) time.Time { return row.CreatedAt })
	})
	t.Run("rejections", func(t *testing.T) {
		s := New(contracts.Config{})
		checkTelemetryReadBuffer(t,
			func(rows []contracts.RejectionRecord) { s.inferenceRejections = rows },
			s.RejectionRecordsSince,
			func(at time.Time) contracts.RejectionRecord { return contracts.RejectionRecord{CreatedAt: at} },
			func(row contracts.RejectionRecord) time.Time { return row.CreatedAt })
	})
	t.Run("request profiles", func(t *testing.T) {
		s := New(contracts.Config{})
		checkTelemetryReadBuffer(t,
			func(rows []contracts.RequestProfileRecord) { s.requestProfiles = rows },
			s.RequestProfilesSince,
			func(at time.Time) contracts.RequestProfileRecord {
				return contracts.RequestProfileRecord{CreatedAt: at}
			},
			func(row contracts.RequestProfileRecord) time.Time { return row.CreatedAt })
	})
	t.Run("fleet snapshots", func(t *testing.T) {
		s := New(contracts.Config{})
		checkTelemetryReadBuffer(t,
			func(rows []contracts.FleetSnapshotRow) { s.fleetSnapshots = rows },
			s.FleetSnapshotsSince,
			func(at time.Time) contracts.FleetSnapshotRow { return contracts.FleetSnapshotRow{SampledAt: at} },
			func(row contracts.FleetSnapshotRow) time.Time { return row.SampledAt })
	})
}

func checkTelemetryReadBuffer[T any](t *testing.T, seed func([]T), read func(time.Time) []T, makeRow func(time.Time) T, timestamp func(T) time.Time) {
	t.Helper()
	// One row beyond the public read limit is sufficient to expose a buffer
	// allocated for the whole history. Seed only these read-path fixtures;
	// ingestion and outcome merging have separate existing tests.
	const count = routerecord.MaxTelemetryReadRows + 1
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	rows := make([]T, count)
	for i := range rows {
		rows[i] = makeRow(base.Add(time.Duration(i) * time.Second))
	}
	seed(rows)
	for _, test := range []struct {
		name  string
		since time.Time
		want  int
	}{
		{"all time", time.Time{}, routerecord.MaxTelemetryReadRows},
		{"inclusive recent window", base.Add(time.Duration(count-3) * time.Second), 3},
		{"no matches", base.Add(time.Duration(count) * time.Second), 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := read(test.since)
			if got == nil || len(got) != test.want {
				t.Fatalf("read returned %d rows (nil=%v), want %d non-nil rows", len(got), got == nil, test.want)
			}
			if cap(got) > routerecord.MaxTelemetryReadRows {
				t.Errorf("read retained capacity for %d rows, above the %d-row read limit", cap(got), routerecord.MaxTelemetryReadRows)
			}
			for i, row := range got {
				want := base.Add(time.Duration(count-1-i) * time.Second)
				if !timestamp(row).Equal(want) {
					t.Fatalf("row %d timestamp = %s, want newest-first %s", i, timestamp(row), want)
				}
			}
		})
	}
}
