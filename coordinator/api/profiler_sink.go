package api

// Batched, bounded, non-blocking sink for profile records.
//
// Separate from the routing-telemetry sink on purpose: profile rows are the
// highest-volume telemetry the coordinator writes, and during the incidents the
// profiler exists to explain (429 cascades, retry storms) the route sink is at
// its busiest. A dedicated buffer means profile pressure can never evict a
// route row, and batching (up to profileBatchMax records or profileBatchWait,
// whichever first) turns per-row store round-trips into one multi-row insert.

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	profileBatchMax  = 64
	profileBatchWait = 250 * time.Millisecond
)

// profileJob is one finalized attempt awaiting flattening + persistence. The
// record is built on the sink worker, never on the finalizing goroutine (which
// may be the provider WS read loop).
type profileJob struct {
	rp *registry.RequestProfile
	ap *registry.AttemptProfile
}

type profileSink struct {
	s       *Server
	ch      chan profileJob
	done    chan struct{}
	dropped atomic.Int64
	written atomic.Int64
	// built counts rows flattened; sampledOut counts jobs discarded before
	// flattening (tests pin that a sampled-out clean success never builds).
	built      atomic.Int64
	sampledOut atomic.Int64
	closeOnce  sync.Once
}

func newProfileSink(s *Server, capacity int) *profileSink {
	if capacity <= 0 {
		capacity = defaultTelemetrySinkCapacity
	}
	p := &profileSink{
		s:    s,
		ch:   make(chan profileJob, capacity),
		done: make(chan struct{}),
	}
	go p.worker()
	return p
}

// submit enqueues a finalized attempt without blocking; drops (and counts)
// when full.
func (p *profileSink) submit(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	if p == nil || rp == nil || ap == nil {
		return false
	}
	select {
	case p.ch <- profileJob{rp: rp, ap: ap}:
		return true
	default:
		n := p.dropped.Add(1)
		if isPowerOfTen(n) && p.s != nil && p.s.logger != nil {
			p.s.logger.Warn("profile sink dropping records (buffer full) — inference is unaffected",
				"dropped_total", n, "capacity", cap(p.ch))
		}
		if p.s != nil {
			p.s.ddIncr("telemetry.sink_dropped", []string{"sink:profile"})
		}
		return false
	}
}

func (p *profileSink) depth() int {
	if p == nil {
		return 0
	}
	return len(p.ch)
}

func (p *profileSink) droppedTotal() int64 {
	if p == nil {
		return 0
	}
	return p.dropped.Load()
}

func (p *profileSink) close() {
	if p == nil {
		return
	}
	p.closeOnce.Do(func() { close(p.done) })
}

// worker drains the channel into batches and writes each batch with one store
// call inside a panic-safe wrapper. It never spawns per-record goroutines.
func (p *profileSink) worker() {
	batch := make([]*store.RequestProfileRecord, 0, profileBatchMax)
	for {
		select {
		case <-p.done:
			return
		case first := <-p.ch:
			batch = batch[:0]
			if rec := p.build(first); rec != nil {
				batch = append(batch, rec)
			}
			timer := time.NewTimer(profileBatchWait)
		collect:
			for len(batch) < profileBatchMax {
				select {
				case job := <-p.ch:
					if rec := p.build(job); rec != nil {
						batch = append(batch, rec)
					}
				case <-timer.C:
					break collect
				case <-p.done:
					timer.Stop()
					p.flush(batch)
					return
				}
			}
			timer.Stop()
			p.flush(batch)
		}
	}
}

// build applies the sampling rule on the live profile and only then
// flattens the job into a row (sampled-out jobs never pay the flatten). Runs
// on the sink worker; panics are contained by the caller's Recover.
func (p *profileSink) build(job profileJob) *store.RequestProfileRecord {
	defer saferun.Recover(p.s.logger, "profileSink.build")
	record, verdict := p.s.profiler.shouldRecordVerdict(job.rp, job.ap)
	if !record {
		p.sampledOut.Add(1)
		p.s.ddIncr("profiler.records", []string{"status:sampled_out"})
		// A sampled-out attempt never reaches applyProviderProfile, the
		// persisted-row emitter of profiler.provider_profile; emit the
		// verdict the always-record decode already produced so the series
		// counts every decoded profile rather than ~10% of the valid ones.
		if verdict.decoded {
			p.s.emitProviderProfileVerdict(verdict.valid, verdict.reason, verdict.enumFolded)
		}
		return nil
	}
	rec := p.s.buildProfileRecord(job.rp, job.ap)
	if rec == nil {
		return nil
	}
	p.built.Add(1)
	return rec
}

func (p *profileSink) flush(batch []*store.RequestProfileRecord) {
	if len(batch) == 0 || p.s == nil || p.s.store == nil {
		return
	}
	logger := p.s.logger
	defer saferun.Recover(logger, "profileSink")
	if err := p.s.store.RecordRequestProfiles(batch); err != nil {
		if logger != nil {
			logger.Error("request_profiles batch write failed", "rows", len(batch), "error", err)
		}
		p.s.ddCount("profiler.records", int64(len(batch)), []string{"status:write_failed"})
		return
	}
	p.written.Add(int64(len(batch)))
	p.s.ddCount("profiler.records", int64(len(batch)), []string{"status:written"})
}
