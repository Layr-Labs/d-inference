package profiler

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/profilequeue"
)

// Hooks supply the current writer and optional observability. Store is read
// once to decide whether to start a worker, and again for every batch write.
// The caller owns any synchronization around changing its active writer.
type Hooks struct {
	Logger *slog.Logger
	Store  func() profilequeue.Writer
	Incr   func(string, []string)
	Count  func(string, int64, []string)
}

// Profiler owns immutable sampling configuration, record construction and its
// independent profile queue. The request lifecycle remains with its caller.
type Profiler struct {
	enabled    bool
	sampleRate float64
	builder    Builder
	sink       *profilequeue.Sink
}

func New(config Config, hooks Hooks, capacity int) *Profiler {
	config = normalizeConfig(config)
	p := &Profiler{enabled: config.Enabled, sampleRate: config.SampleRate, builder: Builder{Incr: hooks.Incr}}
	if p.enabled && hooks.Store != nil && hooks.Store() != nil {
		p.sink = profilequeue.New(profilequeue.Hooks{
			Logger: hooks.Logger,
			Build:  p.buildQueuedProfile,
			Store:  hooks.Store,
			Incr:   hooks.Incr,
			Count:  hooks.Count,
		}, capacity)
	}
	return p
}

func (p *Profiler) Enabled() bool { return p != nil && p.enabled }
func (p *Profiler) HasSink() bool { return p != nil && p.sink != nil }

// Submit is the finalization boundary: only a nonblocking queue send happens
// here. Flattening, decoding and sampling run on the profile worker.
func (p *Profiler) Submit(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	if !p.Enabled() || !p.HasSink() {
		return false
	}
	return p.sink.Submit(rp, ap)
}

// Close signals the existing queue worker; it does not wait or promise to
// drain all buffered jobs. This differs deliberately from the outcome queue.
func (p *Profiler) Close() {
	if p.HasSink() {
		p.sink.Close()
	}
}

func (p *Profiler) Depth() int {
	if !p.HasSink() {
		return 0
	}
	return p.sink.Depth()
}

func (p *Profiler) DroppedTotal() int64 {
	if !p.HasSink() {
		return 0
	}
	return p.sink.DroppedTotal()
}

func (p *Profiler) buildQueuedProfile(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	rec := p.builder.Build(rp, ap)
	if rec == nil {
		return nil
	}
	if !p.alwaysRecord(rec) && !p.sampled(rp.CoordRequestID) {
		p.builder.incr("profiler.records", []string{"status:sampled_out"})
		return nil
	}
	return rec
}
