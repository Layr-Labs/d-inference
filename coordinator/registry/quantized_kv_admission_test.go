package registry

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A quantized model can exhaust its private grant while a native co-resident
// still has memory. The public capacity feed must not substitute whole-box
// headroom for that model's grant during the heartbeat gap.
func TestModelCapacityQuantizedPrivateGrantCountsPending(t *testing.T) {
	const model = "quantized-model"
	r := New(testLogger())
	p := makeTokenBudgetProvider(t, r, "mixed-box", model, 100, 0, 4_096, 100)
	addAdvertisedModel(p, "native-model")
	p.mu.Lock()
	p.Version = "0.9.0"
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.BackendCapacity.Slots[0].KVBytesPerToken = 6_400
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model: "native-model", State: "idle", MaxConcurrency: 8,
		ActiveTokenBudgetMax: 8_192, KVBytesPerToken: 20_480,
	})
	p.mu.Unlock()

	capacity := func() ModelCapacity {
		t.Helper()
		for _, c := range r.ModelCapacitySnapshot() {
			if c.ModelID == model {
				return c
			}
		}
		t.Fatal("missing quantized model capacity")
		return ModelCapacity{}
	}
	check := func(want int64) {
		t.Helper()
		c := capacity()
		if c.TokenBudgetRemaining != want || c.Ready != (want > 0) {
			t.Fatalf("capacity = %+v, want %d remaining, ready=%v", c, want, want > 0)
		}
	}
	check(4_096)
	pr := &PendingRequest{RequestID: "long", Model: model, EstimatedPromptTokens: 3_584, RequestedMaxTokens: 512}
	if selected, _ := r.ReserveProviderEx(model, pr); selected != p {
		t.Fatal("request fitting the quantized grant was not reserved")
	}
	check(0)
	if candidates, _, _ := r.QuickCapacityCheck(model, 1, 1, RequestTraits{}); candidates != 0 {
		t.Fatal("preflight admitted beyond the private grant")
	}
	if selected, _ := r.ReserveProviderEx(model, &PendingRequest{RequestID: "overflow", Model: model, RequestedMaxTokens: 1}); selected != nil {
		t.Fatal("reservation admitted beyond the private grant")
	}

	// The next heartbeat accounts for the same reservation. It must not be
	// charged twice, and a later release must expose the slot's full budget.
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 3_584
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 512
	p.mu.Unlock()
	check(0)
	p.RemovePending(pr.RequestID)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 0
	p.mu.Unlock()
	check(4_096)
}

// Model weight quantization is identical on both providers. Only the resolved
// slot rate and token grant distinguish native from quantized KV admission.
func TestQuantizedKVCapacityRemainsProviderLocal(t *testing.T) {
	const model = "same-artifact"
	r := New(testLogger())
	native := makeTokenBudgetProvider(t, r, "native", model, 100, 0, 1_280, 100)
	quantized := makeTokenBudgetProvider(t, r, "quantized", model, 100, 0, 4_096, 100)
	for _, entry := range []struct {
		p    *Provider
		rate int64
	}{{native, 20_480}, {quantized, 6_400}} {
		entry.p.mu.Lock()
		entry.p.Version = "0.9.0"
		entry.p.BackendCapacity.Slots[0].KVBytesPerToken = entry.rate
		entry.p.BackendCapacity.Slots[0].MaxConcurrency = 8
		entry.p.mu.Unlock()
	}
	if candidates, rejections, _ := r.QuickCapacityCheck(model, 2_500, 500, RequestTraits{}); candidates != 1 || rejections != 1 {
		t.Fatalf("preflight candidates/rejections = %d/%d, want 1/1", candidates, rejections)
	}
	long := &PendingRequest{RequestID: "long", Model: model, EstimatedPromptTokens: 2_500, RequestedMaxTokens: 500}
	if p, _ := r.ReserveProviderEx(model, long); p != quantized {
		t.Fatal("long request did not select the provider with the larger resolved token grant")
	}
	// The native provider still cannot fit 1,500 tokens; the quantized peer now
	// has only 1,096 tokens left. Neither may borrow the other's capacity.
	if p, _ := r.ReserveProviderEx(model, &PendingRequest{RequestID: "too-long", Model: model, RequestedMaxTokens: 1_500}); p != nil {
		t.Fatal("mixed fleet admitted beyond either provider's remaining grant")
	}
	if p, _ := r.ReserveProviderEx(model, &PendingRequest{RequestID: "short", Model: model, RequestedMaxTokens: 1_000}); p == nil {
		t.Fatal("short request was blocked behind the long request despite independent headroom")
	}
}

func TestQuantizedKVConcurrentReservationsRespectMemoryAndCompute(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		for _, tc := range []struct {
			name   string
			budget int64
			cap    int
			want   int32
		}{{"memory", 4_096, 8, 4}, {"compute", 1_000_000, 2, 2}} {
			t.Run(tc.name, func(t *testing.T) {
				const model = "quantized-concurrent"
				r := New(testLogger())
				setReserveCommitModeForTest(r, mode)
				r.SetQualityConcurrencyCap(false, 1, 1, 1)
				p := makeTokenBudgetProvider(t, r, "quantized", model, 100, 0, tc.budget, 100)
				p.mu.Lock()
				p.Version = "0.9.0"
				p.BackendCapacity.Slots[0].KVBytesPerToken = 6_400
				p.BackendCapacity.Slots[0].MaxConcurrency = tc.cap
				p.mu.Unlock()
				var admitted atomic.Int32
				var wg sync.WaitGroup
				start := make(chan struct{})
				for i := range 32 {
					wg.Add(1)
					go func(i int) {
						defer wg.Done()
						<-start
						pr := &PendingRequest{RequestID: fmt.Sprintf("r%d", i), Model: model, EstimatedPromptTokens: 768, RequestedMaxTokens: 256}
						if selected, _ := r.ReserveProviderEx(model, pr); selected != nil {
							admitted.Add(1)
						}
					}(i)
				}
				close(start)
				wg.Wait()
				if got := admitted.Load(); got != tc.want {
					t.Fatalf("admitted %d, want %d under %s bound", got, tc.want, tc.name)
				}
				if candidates, _, _ := r.QuickCapacityCheck(model, 768, 256, RequestTraits{}); candidates != 0 {
					t.Fatal("preflight advertised capacity beyond the saturated bound")
				}
			})
		}
	})
}

func TestQuantizedKVHeartbeatBudgetChangesWakeQueue(t *testing.T) {
	r := New(testLogger())
	p := makeTokenBudgetProvider(t, r, "quantized", drainTestModel, 100, 0, 0, 100)
	p.mu.Lock()
	p.Version = "0.9.0"
	p.BackendCapacity.Slots[0].KVBytesPerToken = 6_400
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.mu.Unlock()
	heartbeat := func(seq uint64, budget int64) {
		t.Helper()
		hb := drainTestHeartbeat(0, budget)
		hb.BackendCapacity.CapacitySeq = seq
		hb.BackendCapacity.Slots[0].KVBytesPerToken = 6_400
		hb.BackendCapacity.Slots[0].MaxConcurrency = 8
		hb.BackendCapacity.Slots[0].NumRunning = 0
		r.Heartbeat(p.ID, hb)
	}
	first := drainTestEnqueue(t, r, drainTestPending("first", 1_536, 512))
	r.DrainQueuedRequestsForModel(drainTestModel)
	drainTestAssertQueued(t, first)
	heartbeat(1, 4_096)
	if selected := drainTestAwait(t, r, first); selected != p {
		t.Fatal("increased quantized grant did not wake the queued request")
	}
	p.RemovePending(first.RequestID)
	heartbeat(2, 1_024)
	second := drainTestEnqueue(t, r, drainTestPending("second", 1_536, 512))
	r.DrainQueuedRequestsForModel(drainTestModel)
	drainTestAssertQueued(t, second)
	// A reordered older budget must not re-admit the request after shrink.
	heartbeat(1, 4_096)
	if candidates, _, _ := r.QuickCapacityCheck(drainTestModel, 1_536, 512, RequestTraits{}); candidates != 0 {
		t.Fatal("stale increased grant replaced the newer shrunken grant")
	}
	drainTestAssertQueued(t, second)
	heartbeat(3, 4_096)
	if selected := drainTestAwait(t, r, second); selected != p {
		t.Fatal("fresh budget recovery did not wake the queued request")
	}
}

// Fixed/window/physical-pool overhead reduces the provider's reported token
// ceiling; it must not be encoded as extra "used tokens" that would cancel
// unrelated pending requests during heartbeat de-duplication.
func TestQuantizedKVOverheadCeilingPreservesPendingDebit(t *testing.T) {
	const model = "quantized-overhead"
	r := New(testLogger())
	// Physical grant buys 4096 marginal tokens, with 1024 token-equivalent
	// bytes already occupied by non-token state. 512 actual tokens are live.
	p := makeTokenBudgetProvider(t, r, "quantized", model, 100, 512, 3_072, 100)
	p.mu.Lock()
	p.Version = "0.9.0"
	p.BackendCapacity.Slots[0].KVBytesPerToken = 6_400
	p.BackendCapacity.Slots[0].MaxTokensPotential = 512
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.mu.Unlock()
	p.AddPending(&PendingRequest{RequestID: "reflected", Model: model, RequestedMaxTokens: 512})
	if selected, _ := r.ReserveProviderEx(model, &PendingRequest{
		RequestID: "in-gap", Model: model, EstimatedPromptTokens: 2_000, RequestedMaxTokens: 500,
	}); selected != p {
		t.Fatal("request fitting the overhead-adjusted grant was rejected")
	}
	if candidates, _, _ := r.QuickCapacityCheck(model, 0, 61, RequestTraits{}); candidates != 0 {
		t.Fatal("overhead-adjusted budget erased some of the new pending debit")
	}
	if selected, _ := r.ReserveProviderEx(model, &PendingRequest{
		RequestID: "remaining", Model: model, RequestedMaxTokens: 60,
	}); selected != p {
		t.Fatal("final 60 tokens of the overhead-adjusted grant were lost")
	}
	for _, c := range r.ModelCapacitySnapshot() {
		if c.ModelID == model && (c.TokenBudgetRemaining != 0 || c.Ready) {
			t.Fatalf("fully debited grant still advertises %+v", c)
		}
	}
	if selected, _ := r.ReserveProviderEx(model, &PendingRequest{
		RequestID: "overflow", Model: model, RequestedMaxTokens: 1,
	}); selected != nil {
		t.Fatal("overhead-adjusted grant overcommitted in the heartbeat gap")
	}
}
