package registry

// Request-path lock probes. They reuse the fleet fixture from
// fleet_scale_bench_test.go and separate three questions:
//   A. do RLock-only fleet walks parallelize?               (RequestPathWalkParallel)
//   B. what does one writer wait under N concurrent walks?  (RequestPathWalkParallelWithWriter)
//   C. scan+commit+per-request recorders, serial vs parallel (RequestPathSerial / RequestPathParallel)
//
// C is the one that measures the change this branch makes: before it, every
// commit and every completion recorder took the registry WRITE lock, so the
// parallel variant ran at ~1x the serial one (each writer drained the whole
// reader batch). TestRequestPathParallelSpeedup (reserve_commit_test.go) pins
// the ratio so a walk-wide lock cannot sneak back.
//
//	go test ./registry/ -run xxx -bench 'RequestPath' -benchtime 2s -benchmem

import (
	"sync/atomic"
	"testing"
	"time"
)

func BenchmarkRequestPathWalkParallel(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		n := 0
		for pb.Next() {
			model := f.models[n%len(f.models)]
			c, _, _, _, _ := f.reg.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, RequestTraits{}, false)
			if c == 0 {
				b.Fatal("no candidates")
			}
			n++
		}
	})
}

// One background writer records a provider outcome every 2 ms (~500/s, the
// prod per-request recorder rate) while RunParallel walkers scan the fleet.
// Reports the mean and max writer wait.
func BenchmarkRequestPathWalkParallelWithWriter(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	var waitNS, waitMax, calls atomic.Int64
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		t := time.NewTicker(2 * time.Millisecond)
		defer t.Stop()
		i := 0
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				id := f.ids[i%len(f.ids)]
				i++
				t0 := time.Now()
				f.reg.RecordProviderOutcome(id, true, 200, "")
				d := time.Since(t0).Nanoseconds()
				waitNS.Add(d)
				calls.Add(1)
				for {
					m := waitMax.Load()
					if d <= m || waitMax.CompareAndSwap(m, d) {
						break
					}
				}
			}
		}
	}()
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		n := 0
		for pb.Next() {
			model := f.models[n%len(f.models)]
			c, _, _, _, _ := f.reg.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, RequestTraits{}, false)
			if c == 0 {
				b.Fatal("no candidates")
			}
			n++
		}
	})
	b.StopTimer()
	close(stop)
	<-done
	if n := calls.Load(); n > 0 {
		b.ReportMetric(float64(waitNS.Load())/float64(n)/1e3, "writer_wait_us/op")
		b.ReportMetric(float64(waitMax.Load())/1e3, "writer_wait_max_us")
	}
}

// requestPathOnce mirrors the per-request registry write sequence of a served
// request: commit (inside ReserveProviderEx) + first-content accept + the
// three completion recorders + the completion-time cooldown clear.
func requestPathOnce(tb testing.TB, f *benchFleet, model string, n int) {
	pr := benchPendingRequest(model, n)
	p, _ := f.reg.ReserveProviderEx(model, pr)
	if p == nil {
		tb.Fatal("no provider reserved")
	}
	f.reg.RecordCapacityAccept(p.ID, model)
	f.reg.RecordInferenceSuccess(p.ID, model, "")
	f.reg.RecordCapacityAcceptOutcome(p.ID, model, false)
	f.reg.RecordProviderOutcome(p.ID, true, 200, "")
	if sid := f.reg.GetProviderStableIdentity(p.ID); sid != "" {
		f.reg.RecordProviderServeOutcome(sid, true, 200, "")
	}
	f.reg.ClearDispatchLoadCooldown(p.ID, model)
	p.RemovePending(pr.RequestID)
}

func BenchmarkRequestPathSerial(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		requestPathOnce(b, f, f.models[i%len(f.models)], i)
	}
}

func BenchmarkRequestPathParallel(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		n := 0
		for pb.Next() {
			requestPathOnce(b, f, f.models[n%len(f.models)], n)
			n++
		}
	})
}
