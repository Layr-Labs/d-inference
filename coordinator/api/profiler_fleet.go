package api

// Fleet snapshot sampler and telemetry retention sweeps.
//
// Both run on their own goroutines with their own store calls (never through
// the request-path telemetry sinks): the sampler bulk-inserts one row per
// (provider, slot) plus one coordinator row every fleetSampleInterval; the
// sweep deletes rows older than the retention constants in bounded batches.

import (
	"context"
	"runtime"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// StartProfilerLoops starts the fleet sampler and the retention sweep. Both
// exit when ctx is cancelled. No-op when the profiler is off or there is no
// store.
func (s *Server) StartProfilerLoops(ctx context.Context) {
	if s.store == nil {
		return
	}
	// Retention runs even with the profiler off so previously written rows
	// stay bounded; sampling only when on.
	saferun.Go(s.logger, "profiler.retention", func() { s.profileRetentionLoop(ctx, profilePruneInterval) })
	if !s.profilerEnabled() {
		return
	}
	saferun.Go(s.logger, "profiler.fleetSampler", func() { s.fleetSamplerLoop(ctx, fleetSampleInterval) })
}

func (s *Server) fleetSamplerLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			s.sampleFleetOnce(now)
		}
	}
}

// sampleFleetOnce takes one fleet sample and writes it. Exported for tests via
// SampleFleetNow.
func (s *Server) sampleFleetOnce(now time.Time) {
	defer saferun.Recover(s.logger, "profiler.sampleFleet")
	if s.registry == nil || s.store == nil {
		return
	}
	rows := s.registry.FleetSample(now)
	coord := s.registry.CoordinatorSample(now)
	coord.Goroutines = runtime.NumGoroutine()
	// Writer-wait p95 on Registry.mu over the sampler's own window (since the
	// previous fleet sample — LockWaitSample owns its reset, independent of
	// the 15 s gauge loop). NULL when no exclusive acquisition happened in
	// the window: "no sample" must never read as "writers waited 0 µs".
	if lw := s.registry.LockWaitSample(); lw.Count > 0 {
		p95 := lw.P95US
		coord.ReserveLockWaitP95US = &p95
	}
	if s.profiler != nil && s.profiler.sink != nil {
		coord.ProfileSinkDepth = s.profiler.sink.depth()
		coord.ProfileSinkDroppedTotal = s.profiler.sink.droppedTotal()
	}
	if s.routeTelemetry != nil {
		coord.RouteSinkDroppedTotal = s.routeTelemetry.dropped.Load()
	}
	registry.ClampFleetRowInts(&coord) // goroutines / sink depth are INT columns too
	coord.UnknownRequestFramesTotal = s.unknownRequestFrames.Load()
	rows = append(rows, coord)
	if err := s.store.RecordFleetSnapshots(rows); err != nil {
		if s.logger != nil {
			s.logger.Error("fleet_snapshots write failed", "rows", len(rows), "error", err)
		}
		s.ddIncr("profiler.fleet_snapshot", []string{"status:write_failed"})
		return
	}
	s.ddCount("profiler.fleet_snapshot", int64(len(rows)), []string{"status:written"})
	if s.profiler != nil && s.profiler.sink != nil {
		s.ddGauge("telemetry.sink_depth", float64(s.profiler.sink.depth()), []string{"sink:profile"})
	}
	if s.routeTelemetry != nil {
		s.ddGauge("telemetry.sink_depth", float64(len(s.routeTelemetry.ch)), []string{"sink:route"})
	}
}

// SampleFleetNow takes one fleet sample synchronously (tests and admin tooling).
func (s *Server) SampleFleetNow() { s.sampleFleetOnce(time.Now()) }

func (s *Server) profileRetentionLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.pruneTelemetryOnce(ctx)
		}
	}
}

// pruneTelemetryOnce runs one bounded retention sweep.
func (s *Server) pruneTelemetryOnce(ctx context.Context) {
	defer saferun.Recover(s.logger, "profiler.prune")
	if s.store == nil {
		return
	}
	sweepCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	now := time.Now()
	deleted, err := s.store.PruneTelemetry(sweepCtx, now.Add(-profileRetainProfiles), now.Add(-profileRetainFleet), profilePruneBatch)
	if err != nil && s.logger != nil {
		s.logger.Warn("telemetry retention sweep stopped early", "deleted", deleted, "error", err)
	}
	if deleted > 0 {
		s.ddCount("profiler.pruned_rows", int64(deleted), nil)
	}
}

// PruneTelemetryNow runs one retention sweep synchronously (tests/admin).
func (s *Server) PruneTelemetryNow(ctx context.Context) { s.pruneTelemetryOnce(ctx) }

var _ = store.FleetSnapshotRow{}
