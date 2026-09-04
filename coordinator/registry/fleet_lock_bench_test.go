package registry

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// BenchmarkFleetLockContention is the Registry.mu writer-queue instrument:
// the acceptance bench for the recorder / commit lock work.
//
// 32 writer goroutines run the whole served-request write sequence per op —
// reserve (commit under r.mu.Lock), the commit-time capacity accept, the
// pending release, and the four completion-time recorders — while 64 reader
// goroutines hammer the capacity preflight (an RLock-held fleet walk) on the
// 1,260-provider fixture. Under Go's RWMutex each queued writer waits out the
// in-flight reader batch, so this reproduces the 2026-08-31 shape (writers
// parked for seconds behind reader batches). Reported metrics come from
// LockWaitSnapshot: writer wait p50 / p99 / max (µs), the peak number of
// parked writers, and reserves/s.
//
//	go test ./registry/ -run '^$' -bench 'FleetLockContention' -benchmem
func BenchmarkFleetLockContention(b *testing.B) {
	const writers, readers = 32, 64
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	reg := f.reg
	reg.LockWaitSnapshot() // discard fixture-build acquisitions

	stop := make(chan struct{})
	var readerWG sync.WaitGroup
	for r := 0; r < readers; r++ {
		readerWG.Add(1)
		go func(r int) {
			defer readerWG.Done()
			model := f.models[r%len(f.models)]
			for {
				select {
				case <-stop:
					return
				default:
				}
				reg.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, RequestTraits{}, false)
			}
		}(r)
	}
	// Sample the parked-writer gauge every millisecond for its peak.
	var peakWaiting atomic.Int32
	var samplerWG sync.WaitGroup
	samplerWG.Add(1)
	go func() {
		defer samplerWG.Done()
		tick := time.NewTicker(time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tick.C:
				if w := reg.LockWaitPeek().WritersWaiting; w > peakWaiting.Load() {
					peakWaiting.Store(w)
				}
			}
		}
	}()

	var failures atomic.Int64
	perWriter := b.N / writers
	if perWriter < 1 {
		perWriter = 1
	}
	b.ReportAllocs()
	b.ResetTimer()
	start := time.Now()
	var writerWG sync.WaitGroup
	for w := 0; w < writers; w++ {
		writerWG.Add(1)
		go func(w int) {
			defer writerWG.Done()
			model := f.models[w%len(f.models)]
			for i := 0; i < perWriter; i++ {
				pr := benchPendingRequest(model, w*perWriter+i)
				p, _ := reg.ReserveProviderEx(model, pr)
				if p == nil {
					failures.Add(1)
					continue
				}
				// Served path: commit-time accept, release, completion recorders.
				if reg.RecordCapacityAccept(p.ID, model) {
					pr.MarkRateOutcomeCounted()
				}
				p.RemovePending(pr.RequestID)
				reg.RecordInferenceSuccess(p.ID, model, "base")
				reg.RecordCapacityAcceptOutcome(p.ID, model, !pr.RateOutcomeCountedSafe())
				reg.RecordProviderOutcome(p.ID, true, 200, "")
				reg.RecordProviderServeOutcome(p.ID, true, 200, "")
				reg.ClearDispatchLoadCooldown(p.ID, model)
			}
		}(w)
	}
	writerWG.Wait()
	elapsed := time.Since(start)
	b.StopTimer()
	close(stop)
	readerWG.Wait()
	samplerWG.Wait()

	if failures.Load() > 0 {
		b.Fatalf("%d reservations failed", failures.Load())
	}
	lw := reg.LockWaitSnapshot()
	b.ReportMetric(float64(writers*perWriter)/elapsed.Seconds(), "reserves/s")
	b.ReportMetric(float64(lw.P50US), "wait_p50_us")
	b.ReportMetric(float64(lw.P99US), "wait_p99_us")
	b.ReportMetric(float64(lw.MaxUS), "wait_max_us")
	b.ReportMetric(float64(lw.Count)/float64(writers*perWriter), "locks/op")
	b.ReportMetric(float64(peakWaiting.Load()), "writers_waiting_peak")
}
