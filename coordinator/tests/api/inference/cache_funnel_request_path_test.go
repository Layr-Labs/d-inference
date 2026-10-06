package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const cacheFunnelModel = "planning-fixture"

// cacheFunnelFixture is the composed coordinator with two real provider
// connections and verified prompt artifacts. Requests go through the real HTTP
// handlers; the funnel is read from the same projection GET /v1/cache/status
// serves.
type cacheFunnelFixture struct {
	ctx       context.Context
	reg       *registry.Registry
	server    *serverFixture
	transport *httptest.Server
	planning  *cachePlanningUDSFixture
	serve     atomic.Pointer[inferenceScript]
	// capabilities is each provider's published cache capability by registry
	// ID: what a receipt from that provider must carry.
	capabilities map[string]protocol.PrefixCacheV2Capability
	receiptSeq   atomic.Uint64
}

func newCacheFunnelFixture(t *testing.T) *cacheFunnelFixture {
	t.Helper()
	// An exempt account keeps the first-content clock out of planning, so a
	// blocked or failed planner never turns into an admission rejection.
	reg, _, server, transport := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentSLAAccounts: []string{}})
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f := &cacheFunnelFixture{ctx: ctx, reg: reg, server: server, transport: transport,
		capabilities: make(map[string]protocol.PrefixCacheV2Capability)}
	f.serveWith(fullServeScript(cacheFunnelModel))
	var ids []string
	providers := make([]*failoverProvider, 0, 2)
	for i := range 2 {
		fp := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
			Name: fmt.Sprintf("funnel-provider-%d", i), Version: "0.8.15", DecodeTPS: float64(200 - i*100),
			Models: []failoverModelSpec{{ID: cacheFunnelModel}},
			Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
				(*f.serve.Load())(ctx, fp, req, body)
			},
		})
		setPrefixCacheProtocol(t, reg, fp, 1)
		providers, ids = append(providers, fp), append(ids, fp.registryID)
	}
	f.planning = newCachePlanningUDSFixture(t, server.Owner, server.registry, ids...)
	for i, fp := range providers {
		capability := cacheEligibilityV2Capability(cacheFunnelModel)
		capability.ModelAggregateHash, capability.PromptContractID = f.planning.aggregate, f.planning.contract
		capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
		capability.CacheEpoch = []string{"11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"}[i]
		if err := reg.UpdatePrefixCacheCapabilities(fp.registryID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
			t.Fatal(err)
		}
		f.capabilities[fp.registryID] = capability
	}
	return f
}

func (f *cacheFunnelFixture) serveWith(script inferenceScript) { f.serve.Store(&script) }

func (f *cacheFunnelFixture) post(t *testing.T, endpoint, body string) int {
	t.Helper()
	status, _, err := postGenericInference(f.ctx, f.transport.URL, endpoint, body)
	if err != nil {
		t.Fatal(err)
	}
	return status
}

// settled waits for every entered request to close: a handler writes its
// response before its deferred close runs.
func (f *cacheFunnelFixture) settled(t *testing.T) cachefunnel.PublicStatus {
	t.Helper()
	awaitCondition(t, 10*time.Second, func() bool {
		funnel := f.server.ExactCacheStatusSnapshot().Funnel
		return funnel.InFlight == 0 && funnel.Entered == funnel.Closed
	}, "every funnel request closed")
	funnel := f.server.ExactCacheStatusSnapshot().Funnel
	// Usage reaches the funnel only after validation, which rejects a hit that
	// names no tier, so on the request path the tier split sums to the hits.
	hits := cacheFunnelReason(funnel, cachefunnel.Hit).Requests + cacheFunnelReason(funnel, cachefunnel.HitWithoutSelection).Requests
	if funnel.Total.MemoryHitRequests+funnel.Total.SSDHitRequests != hits {
		t.Fatalf("memory %d + ssd %d hit requests != %d requests under the hit reasons",
			funnel.Total.MemoryHitRequests, funnel.Total.SSDHitRequests, hits)
	}
	return funnel
}

// awaitCounter waits for an admin metrics counter. The ledger hands a closed
// record to its sink after the public counts already show the request, so a
// token sum can trail them.
func (f *cacheFunnelFixture) awaitCounter(t *testing.T, key string, want int64) {
	t.Helper()
	awaitCondition(t, 5*time.Second, func() bool {
		return f.server.observation.Metrics().Snapshot().Counters[key] == want
	}, fmt.Sprintf("%s = %d", key, want))
}

func cacheFunnelReason(funnel cachefunnel.PublicStatus, reason cachefunnel.Reason) cachefunnel.PublicTotals {
	for _, totals := range funnel.Reasons {
		if totals.Reason == reason.String() {
			return totals.PublicTotals
		}
	}
	return cachefunnel.PublicTotals{}
}

// requireOneMoreRequest asserts that exactly one request entered and closed
// since before, under want and no other reason, with the given attempts.
func requireOneMoreRequest(t *testing.T, before, after cachefunnel.PublicStatus, want cachefunnel.Reason, attempts uint64) {
	t.Helper()
	if after.Entered != before.Entered+1 || after.Closed != before.Closed+1 || after.InFlight != 0 {
		t.Fatalf("entered %d->%d closed %d->%d in flight %d, want exactly one request entered and closed",
			before.Entered, after.Entered, before.Closed, after.Closed, after.InFlight)
	}
	gainedReasons := make(map[string]uint64)
	for i, reason := range after.Reasons {
		if gained := reason.Requests - before.Reasons[i].Requests; gained != 0 {
			gainedReasons[reason.Reason] = gained
		}
		if reason.Reason == want.String() && reason.Attempts-before.Reasons[i].Attempts != attempts {
			t.Fatalf("%s gained %d attempts, want %d", reason.Reason, reason.Attempts-before.Reasons[i].Attempts, attempts)
		}
	}
	if len(gainedReasons) != 1 || gainedReasons[want.String()] != 1 {
		t.Fatalf("request ended as %v, want exactly one request under %s", gainedReasons, want)
	}
	if after.Total.Requests != after.Closed || after.Total.Attempts != before.Total.Attempts+attempts {
		t.Fatalf("total = %+v, want %d requests and %d more attempts", after.Total, after.Closed, attempts)
	}
}

// plannerStandIn is the local tokenizer transport only: it answers plan calls
// with the same synthetic plan as the fixture's sidecar, fails them, or holds
// them until released. Readiness and artifacts stay with the real fixture.
type plannerStandIn struct {
	client  *promptcontract.Client
	fail    atomic.Bool
	active  atomic.Int32
	mu      sync.Mutex
	blocked chan struct{}
}

func newPlannerStandIn(t *testing.T) *plannerStandIn {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "cache-funnel-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	socket := filepath.Join(root, "s.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	p := &plannerStandIn{}
	server := &http.Server{Handler: http.HandlerFunc(p.plan)}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	p.client = promptcontract.NewClient(promptcontract.ClientConfig{
		SocketPath: socket, RequestTimeout: 5 * time.Second, MaxConcurrency: 32, MaxConnections: 64,
	})
	t.Cleanup(p.client.Close)
	return p
}

func (p *plannerStandIn) plan(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Contract string `json:"prompt_contract_id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
		http.Error(w, "invalid stand-in plan", http.StatusBadRequest)
		return
	}
	p.active.Add(1)
	defer p.active.Add(-1)
	p.mu.Lock()
	blocked := p.blocked
	p.mu.Unlock()
	if blocked != nil {
		select {
		case <-blocked:
		case <-r.Context().Done():
			return
		}
	}
	if p.fail.Load() {
		http.Error(w, "stand-in planner failure", http.StatusInternalServerError)
		return
	}
	hash := strings.Repeat("c", 64)
	_ = json.NewEncoder(w).Encode(promptcontract.Plan{
		PromptContractID: request.Contract, PromptTokenCount: 257,
		BlockBoundaries:       []promptcontract.Boundary{{TokenCount: 256, ChainHash: hash}},
		LastCompleteBlockHash: &hash,
	})
}

// block holds every later plan call until the returned release runs.
func (p *plannerStandIn) block() (release func()) {
	blocked := make(chan struct{})
	p.mu.Lock()
	p.blocked = blocked
	p.mu.Unlock()
	return sync.OnceFunc(func() {
		p.mu.Lock()
		p.blocked = nil
		p.mu.Unlock()
		close(blocked)
	})
}

func TestCacheFunnelFollowsRealRequests(t *testing.T) {
	f := newCacheFunnelFixture(t)
	chat := cachePlanningEndpointBody(cacheFunnelModel, "/v1/chat/completions", false)

	t.Run("a planned text request enters once and ends by what its provider reported", func(t *testing.T) {
		f.serveWith(func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			fp.sendRoleChunk(ctx, req, cacheFunnelModel)
			fp.sendContentChunk(ctx, req, cacheFunnelModel, markerFor(fp.name))
			fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 257, CompletionTokens: 3,
				CacheOutcome: "hit", CacheTier: "memory", CachedTokens: 256, PrefillTokensSaved: 256})
		})
		defer f.serveWith(fullServeScript(cacheFunnelModel))
		before := f.settled(t)
		if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
		after := f.settled(t)
		// No holder was selected for a first-time prompt, so the reported hit
		// is the only evidence that ranks this request above a routing loss.
		requireOneMoreRequest(t, before, after, cachefunnel.HitWithoutSelection, 1)
		hit := cacheFunnelReason(after, cachefunnel.HitWithoutSelection)
		if hit.LookupOutcomeReported != 1 || hit.DispatchedWithoutScope != 0 || hit.PromptTokensUnknown != 0 || hit.ReusedTokensUnknown != 0 {
			t.Fatalf("hit_without_selection = %+v, want a scoped attempt with its outcome, prompt and reused tokens observed", hit)
		}
		// The exact token counts are held back from the public status and
		// reach the admin metrics registry only.
		for key, want := range map[string]int64{
			"exact_cache_funnel_prompt_tokens_total{reason=hit_without_selection}":                    257,
			"exact_cache_funnel_provider_prompt_tokens_total{reason=hit_without_selection}":           257,
			"exact_cache_funnel_reused_tokens_total{reason=hit_without_selection,tier=memory}":        256,
			"exact_cache_funnel_prefill_saved_tokens_total{reason=hit_without_selection,tier=memory}": 256,
		} {
			f.awaitCounter(t, key, want)
		}
		if hit.MemoryHitRequests != 1 || hit.SSDHitRequests != 0 || hit.Planned != 1 || hit.Dispatched != 1 {
			t.Fatalf("hit_without_selection = %+v, want one planned, dispatched memory-tier hit", hit)
		}
		requireNoTokenSums(t, f.transport.URL)
	})

	t.Run("the generic endpoint handler enters and closes its requests too", func(t *testing.T) {
		before := f.settled(t)
		if status := f.post(t, "/v1/completions", cachePlanningEndpointBody(cacheFunnelModel, "/v1/completions", false)); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
		after := f.settled(t)
		if after.Entered != before.Entered+1 || after.Closed != before.Closed+1 || after.Total.Attempts != before.Total.Attempts+1 {
			t.Fatalf("before %+v after %+v, want one more request with one attempt", before, after)
		}
		if got := planningAndDispatchStageRequests(after) - planningAndDispatchStageRequests(before); got != 0 {
			t.Fatalf("a planned, served request was charged to a planning or dispatch reason: %+v", after.Reasons)
		}
	})

	t.Run("a retried request stays one request with two attempts", func(t *testing.T) {
		var order dispatchRecorder
		f.serveWith(failFirstScript(&order, cacheFunnelModel, "error"))
		defer f.serveWith(fullServeScript(cacheFunnelModel))
		before := f.settled(t)
		if status := f.post(t, "/v1/chat/completions", strings.Replace(chat, `"stream":false`, `"stream":true`, 1)); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
		after := f.settled(t)
		if after.Entered != before.Entered+1 || after.Closed != before.Closed+1 || after.Total.Requests != before.Total.Requests+1 {
			t.Fatalf("before %+v after %+v, want the retry counted as one request", before, after)
		}
		if after.Total.Attempts != before.Total.Attempts+2 {
			t.Fatalf("attempts %d -> %d, want both provider attempts on the one request", before.Total.Attempts, after.Total.Attempts)
		}
	})

	t.Run("a client that leaves after dispatch closes with one attempt and its routing reason", func(t *testing.T) {
		received := make(chan struct{}, 1)
		release := make(chan struct{})
		defer close(release)
		f.serveWith(func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			fp.sendRoleChunk(ctx, req, cacheFunnelModel)
			select {
			case received <- struct{}{}:
			default:
			}
			<-release
		})
		defer f.serveWith(fullServeScript(cacheFunnelModel))
		before := f.settled(t)
		ctx, cancel := context.WithCancel(f.ctx)
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _, _ = postGenericInference(ctx, f.transport.URL, "/v1/chat/completions", chat)
		}()
		select {
		case <-received:
		case <-time.After(5 * time.Second):
			t.Fatal("provider never received the request")
		}
		cancel()
		<-done
		// The prompt repeats earlier subtests' prompt, but no provider is
		// recorded as holding it, so the routing stage had already ruled reuse
		// out before the client left: the request is charged to that stage, not
		// to cancelled_after_dispatch (which needs a selected holder), and the
		// one attempt the provider received is still counted.
		requireOneMoreRequest(t, before, f.settled(t), cachefunnel.RepeatWithoutHolder, 1)
	})

	t.Run("a media request does not enter", func(t *testing.T) {
		before := f.settled(t)
		media := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":[{"type":"text","text":"planning lifecycle fixture"},`+
			`{"type":"input_audio","input_audio":{"data":"AAAA","format":"wav"}}]}],"max_tokens":16,"stream":false}`, cacheFunnelModel)
		status := f.post(t, "/v1/chat/completions", media)
		if after := f.settled(t); after.Entered != before.Entered {
			t.Fatalf("media request (status %d) entered the funnel: %d -> %d", status, before.Entered, after.Entered)
		}
	})

	standIn := newPlannerStandIn(t)
	f.server.SetPromptContractClient(standIn.client)

	t.Run("a served request whose plan failed ends as plan_failed", func(t *testing.T) {
		standIn.fail.Store(true)
		defer standIn.fail.Store(false)
		before := f.settled(t)
		if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
		requireOneMoreRequest(t, before, f.settled(t), cachefunnel.PlanFailed, 1)
	})

	t.Run("a client that leaves before dispatch ends as cancelled_before_dispatch", func(t *testing.T) {
		release := standIn.block()
		defer release()
		before := f.settled(t)
		ctx, cancel := context.WithCancel(f.ctx)
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _, _ = postGenericInference(ctx, f.transport.URL, "/v1/chat/completions", chat)
		}()
		awaitCondition(t, 5*time.Second, func() bool { return standIn.active.Load() == 1 }, "request blocked in planning")
		cancel()
		<-done
		requireOneMoreRequest(t, before, f.settled(t), cachefunnel.CancelledBeforeDispatch, 0)
	})

	t.Run("a request refused by the saturated prompt-work gate ends as gate_refused", func(t *testing.T) {
		release := standIn.block()
		defer release()
		before := f.settled(t)
		const gateSlots = 16
		var holders sync.WaitGroup
		for range gateSlots {
			holders.Add(1)
			go func() {
				defer holders.Done()
				_, _, _ = postGenericInference(f.ctx, f.transport.URL, "/v1/chat/completions", chat)
			}()
		}
		awaitCondition(t, 5*time.Second, func() bool { return standIn.active.Load() == gateSlots }, "every gate slot held by a planning request")
		if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
			t.Fatalf("refused request was not served: status = %d", status)
		}
		refused := cacheFunnelReason(f.server.ExactCacheStatusSnapshot().Funnel, cachefunnel.GateRefused)
		release()
		holders.Wait()
		after := f.settled(t)
		if refused.Requests != 1 || refused.Attempts != 1 || refused.PromptTokensUnknown != 1 {
			t.Fatalf("gate_refused = %+v, want the one refused request, served once, prompt tokens unknown", refused)
		}
		if after.Entered != before.Entered+gateSlots+1 || cacheFunnelReason(after, cachefunnel.GateRefused).Requests != 1 {
			t.Fatalf("before %+v after %+v, want %d more requests and only one gate refusal", before, after, gateSlots+1)
		}
	})

	t.Run("a request does not enter while cache routing is off", func(t *testing.T) {
		before := f.settled(t)
		if err := f.reg.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
			t.Fatal(err)
		}
		if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
		if after := f.settled(t); after.Entered != before.Entered || after.Closed != before.Closed {
			t.Fatalf("request entered with routing off: %+v -> %+v", before, after)
		}
	})
}

// planningAndDispatchStageRequests counts requests no provider served with a
// plan: the planning reasons and the two ended-before-dispatch reasons.
func planningAndDispatchStageRequests(funnel cachefunnel.PublicStatus) uint64 {
	var requests uint64
	for _, reason := range []cachefunnel.Reason{
		cachefunnel.NotEligible, cachefunnel.PlannerUnavailable, cachefunnel.GateRefused, cachefunnel.SampledOut,
		cachefunnel.RateLimited, cachefunnel.PlanFailed, cachefunnel.PlanEmpty, cachefunnel.PlanningUnobserved,
		cachefunnel.CancelledBeforeDispatch, cachefunnel.ErroredBeforeDispatch,
	} {
		requests += cacheFunnelReason(funnel, reason).Requests
	}
	return requests
}

// requireNoTokenSums reads the public status over HTTP, as an unauthenticated
// caller would, and fails if any funnel object carries a token sum.
func requireNoTokenSums(t *testing.T, baseURL string) {
	t.Helper()
	response, err := http.Get(baseURL + "/v1/cache/status")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var decoded struct {
		Funnel struct {
			Total   map[string]any   `json:"total"`
			Reasons []map[string]any `json:"reasons"`
		} `json:"funnel"`
	}
	if err := json.NewDecoder(response.Body).Decode(&decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Funnel.Total["requests"] != float64(1) || len(decoded.Funnel.Reasons) == 0 {
		t.Fatalf("public funnel = %+v, want the one closed request counted", decoded.Funnel)
	}
	for _, object := range append(decoded.Funnel.Reasons, decoded.Funnel.Total) {
		for _, sum := range []string{"prompt_tokens", "repeated_prefix_tokens", "predicted_tokens", "reused_tokens",
			"prefill_saved_tokens", "provider_prompt_tokens"} {
			if _, present := object[sum]; present {
				t.Fatalf("public funnel exposes token sum %q: %v", sum, object)
			}
		}
	}
}

// What a provider did not report stays unknown at the request seam: a
// completion with no prompt-token count is not a prompt of zero tokens, and a
// hit that names no tier is rejected before it can count under neither tier.
func TestCacheFunnelKeepsUnreportedProviderUsageUnknown(t *testing.T) {
	f := newCacheFunnelFixture(t)
	chat := cachePlanningEndpointBody(cacheFunnelModel, "/v1/chat/completions", false)
	for _, tc := range []struct {
		name                              string
		usage                             protocol.UsageInfo
		promptUnknown, reusedUnknown, hit uint64
	}{
		{name: "no prompt-token count", usage: protocol.UsageInfo{CompletionTokens: 3, CacheOutcome: "miss_absent", CacheTier: "memory"},
			promptUnknown: 1},
		{name: "a hit that names no tier", usage: protocol.UsageInfo{PromptTokens: 257, CompletionTokens: 3,
			CacheOutcome: "hit", CachedTokens: 256, PrefillTokensSaved: 256}, reusedUnknown: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.serveWith(func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
				fp.sendRoleChunk(ctx, req, cacheFunnelModel)
				fp.sendContentChunk(ctx, req, cacheFunnelModel, markerFor(fp.name))
				fp.sendComplete(ctx, req, tc.usage)
			})
			defer f.serveWith(fullServeScript(cacheFunnelModel))
			before := f.settled(t)
			if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
				t.Fatalf("status = %d", status)
			}
			after := f.settled(t)
			if after.Closed != before.Closed+1 ||
				after.Total.ProviderPromptTokensUnknown != before.Total.ProviderPromptTokensUnknown+tc.promptUnknown ||
				after.Total.ReusedTokensUnknown != before.Total.ReusedTokensUnknown+tc.reusedUnknown ||
				after.Total.MemoryHitRequests+after.Total.SSDHitRequests != before.Total.MemoryHitRequests+before.Total.SSDHitRequests+tc.hit {
				t.Fatalf("before %+v after %+v, want %d more unknown provider prompt, %d more unknown reuse, %d more hits",
					before.Total, after.Total, tc.promptUnknown, tc.reusedUnknown, tc.hit)
			}
		})
	}
}
