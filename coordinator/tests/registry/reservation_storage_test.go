package registry_test

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/candidatearena"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

// Retain public scans and preparation plus copied plans through private churn.
func TestReservationStoragePreservesRetainedOwnership(t *testing.T) {
	for _, decorated := range []bool{false, true} {
		t.Run(fmt.Sprintf("decorated=%t", decorated), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var planner *production.ReservationPlanner
				reg := production.NewWithDependencies(testLogger(), production.Dependencies{Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
					planner = actual
					if decorated {
						return actual
					}
					return nil
				}})
				const model = "optimization-retention"
				for i := 0; i < 73; i++ {
					makeSchedulerProvider(t, reg, fmt.Sprintf("retained-%03d", i), model, 50+float64(i%9))
				}
				scanRequest := planTestRequest("scan", 500, 16)
				scanRequest.Model = model
				old := planner.ScanCandidates(model, scanRequest, false)
				if len(old.Candidates) != 73 {
					t.Fatalf("retained pool=%d, want73", len(old.Candidates))
				}
				saved := make([]production.PlanEntry, len(old.Candidates))
				for i, c := range old.Candidates {
					saved[i] = c.Quote()
				}
				heldRequest := planTestRequest("held", 500, 16)
				heldRequest.Model = model
				held := planner.Prepare(model, heldRequest).Finish()
				heldProvider := held.Provider
				initial := planTestRequest("initial", 500, 16)
				provider, _, plan := reg.ReserveProviderWithPlan(model, initial)
				if provider == nil || plan == nil || plan.Len() == 0 {
					t.Fatal("no retained plan")
				}
				if provider.RemovePending(initial.RequestID) != initial {
					t.Fatal("initial debit not released")
				}
				planLength, remaining := plan.Len(), plan.Remaining()
				next, ok := plan.PeekNext()
				if !ok {
					t.Fatal("empty plan")
				}
				var wg sync.WaitGroup
				for worker := 0; worker < 4; worker++ {
					wg.Add(1)
					go func(worker int) {
						defer wg.Done()
						for i := 0; i < 40; i++ {
							pr := planTestRequest(fmt.Sprintf("churn-%d-%d", worker, i), 500, 16)
							p, _ := reg.ReserveProviderEx(model, pr)
							if p == nil {
								t.Error("churn failed")
								return
							}
							if p.RemovePending(pr.RequestID) != pr {
								t.Error("debit not released")
								return
							}
						}
					}(worker)
				}
				wg.Wait()
				for i, c := range old.Candidates {
					if got := c.Quote(); got != saved[i] {
						t.Fatalf("retained quote %d changed", i)
					}
				}
				if got, ok := plan.PeekNext(); !ok || got != next {
					t.Fatal("retained plan changed")
				}
				if plan.Len() != planLength || plan.Remaining() != remaining {
					t.Fatal("plan dimensions changed")
				}
				canonical := append([]production.PlanEntry(nil), saved...)
				sort.Slice(canonical, func(i, j int) bool { return canonical[i].ProviderID < canonical[j].ProviderID })
				encoded, err := json.Marshal(canonical)
				if err != nil {
					t.Fatal(err)
				}
				t.Logf("quotes=%d digest=%x", len(saved), sha256.Sum256(encoded))
				committed := held.Commit(model, heldRequest)
				if committed.Outcome != production.ReservationCommitted || committed.Provider == nil || committed.Provider != heldProvider {
					t.Fatalf("held commit=%v", committed.Outcome)
				}
				if committed.Provider.RemovePending(heldRequest.RequestID) != heldRequest {
					t.Fatal("held debit not released")
				}
				seen := map[string]bool{provider.ID: true}
				for n := 0; plan.Remaining() > 0; n++ {
					retry := planTestRequest(fmt.Sprintf("plan-retry-%d", n), 500, 16)
					p, _, skips := reg.ReserveNextFromPlan(retry, plan)
					if p == nil {
						t.Fatalf("plan failed: %+v", skips)
					}
					if seen[p.ID] {
						t.Fatalf("plan reused identity %s", p.ID)
					}
					seen[p.ID] = true
					if p.RemovePending(retry.RequestID) != retry {
						t.Fatal("plan debit not released")
					}
				}
				if len(seen) != planLength+1 {
					t.Fatalf("consumed=%d,want=%d", len(seen)-1, planLength)
				}
			})
		})
	}
}
func BenchmarkReservationScale(b *testing.B) {
	for _, providers := range []int{32, 350, 1260, 3000, 6000} {
		for _, models := range []int{2, 15} {
			b.Run(fmt.Sprintf("providers=%d/models=%d", providers, models), func(b *testing.B) {
				f := buildBenchFleet(b, providers, models)
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					model := f.models[i%len(f.models)]
					pr := benchPendingRequest(model, i)
					p, _ := f.reg.ReserveProviderEx(model, pr)
					if p == nil {
						b.Fatal("no provider")
					}
					p.RemovePending(pr.RequestID)
				}
			})
		}
	}
}
func BenchmarkReservationPlan350(b *testing.B) {
	reg := buildReserveBenchFleet(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		model, pr := reserveBenchRequest(i)
		p, _, plan := reg.ReserveProviderWithPlan(model, pr)
		if p == nil || plan == nil || plan.Len() == 0 {
			b.Fatal("no plan")
		}
		p.RemovePending(pr.RequestID)
	}
}
func BenchmarkReservationParallel350(b *testing.B) {
	reg := buildReserveBenchFleet(b)
	var sequence atomic.Uint64
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			n := sequence.Add(1)
			model, pr := reserveBenchRequest(int(n))
			pr.RequestID = fmt.Sprintf("unique-%d", n)
			p, _ := reg.ReserveProviderEx(model, pr)
			if p == nil {
				b.Fatal("no provider")
			}
			if p.RemovePending(pr.RequestID) != pr {
				b.Fatal("missing debit")
			}
		}
	})
}

func BenchmarkReservationReservationWriter(b *testing.B) {
	reg := buildReserveBenchFleet(b)
	var waitNS, waitMax, calls atomic.Int64
	var sequence atomic.Uint64
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(2 * time.Millisecond)
		defer ticker.Stop()
		i := 0
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				id := fmt.Sprintf("bench-%04d", i%350)
				i++
				start := time.Now()
				reg.RecordProviderOutcome(id, true, 200, "")
				elapsed := time.Since(start).Nanoseconds()
				waitNS.Add(elapsed)
				calls.Add(1)
				for {
					maximum := waitMax.Load()
					if elapsed <= maximum || waitMax.CompareAndSwap(maximum, elapsed) {
						break
					}
				}
			}
		}
	}()
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			n := sequence.Add(1)
			model, pr := reserveBenchRequest(int(n))
			pr.RequestID = fmt.Sprintf("writer-%d", n)
			p, _ := reg.ReserveProviderEx(model, pr)
			if p == nil {
				b.Fatal("no provider")
			}
			if p.RemovePending(pr.RequestID) != pr {
				b.Fatal("missing debit")
			}
		}
	})
	b.StopTimer()
	close(stop)
	<-done
	if n := calls.Load(); n > 0 {
		b.ReportMetric(float64(waitNS.Load())/float64(n)/1e3, "writer_wait_us/op")
		b.ReportMetric(float64(waitMax.Load())/1e3, "writer_wait_max_us")
		b.ReportMetric(float64(n), "writer_calls")
	}
}

// The private reservation path crosses its pooling cutoff without changing
// public candidate values or the detached alternates retained by dispatch.
func TestReservationStorageScanSizeBoundary(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var planner *production.ReservationPlanner
		r := production.NewWithDependencies(testLogger(), production.Dependencies{
			Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation { planner = p; return nil },
		})
		const model = "storage-boundary"
		for i := 0; i < candidatearena.MaxReusableCandidates; i++ {
			makeSchedulerProvider(t, r, fmt.Sprintf("boundary-%04d", i), model, 64)
		}
		request := planTestRequest("retained-boundary", 128, 16)
		request.Model = model
		public := planner.ScanCandidates(model, request, false)
		if len(public.Candidates) != candidatearena.MaxReusableCandidates {
			t.Fatalf("public candidates=%d, want %d", len(public.Candidates), candidatearena.MaxReusableCandidates)
		}
		quotes := make([]production.PlanEntry, len(public.Candidates))
		for i, c := range public.Candidates {
			quotes[i] = c.Quote()
		}
		var retained *production.DispatchPlan
		for step := 0; step < 3; step++ {
			if step == 1 {
				makeSchedulerProvider(t, r, "boundary-overflow", model, 64)
			}
			if step == 2 {
				r.Disconnect("boundary-overflow")
			}
			pr := planTestRequest(fmt.Sprintf("boundary-reserve-%d", step), 128, 16)
			pr.Model = model
			p, decision, plan := r.ReserveProviderWithPlan(model, pr)
			if p == nil || decision.CandidateCount != candidatearena.MaxReusableCandidates+step%2 || plan == nil || plan.Len() != 8 {
				t.Fatalf("step=%d reservation/plan failed: provider=%v decision=%+v", step, p, decision)
			}
			if p.RemovePending(pr.RequestID) != pr {
				t.Fatal("reservation debit missing")
			}
			if step == 0 {
				retained = plan
			}
			for i, c := range public.Candidates {
				if c.Quote() != quotes[i] {
					t.Fatalf("step=%d retained quote %d mutated", step, i)
				}
			}
		}
		for retained.Remaining() > 0 {
			pr := planTestRequest(fmt.Sprintf("boundary-alternate-%d", retained.Remaining()), 128, 16)
			p, _, skips := r.ReserveNextFromPlan(pr, retained)
			if p == nil || p.RemovePending(pr.RequestID) != pr {
				t.Fatalf("retained alternate failed: %+v", skips)
			}
		}
	})
}
