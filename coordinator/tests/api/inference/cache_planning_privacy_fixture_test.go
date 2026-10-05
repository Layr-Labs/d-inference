package inference_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/conformance"
)

const (
	privacyPlanningAccountA = "joint-account-a"
	privacyPlanningAccountB = "joint-account-b"
	privacyPlanningMarker   = "JOINT_CACHE_OK"
	privacyPlanningContent  = "nested-user-value nested-metadata-value"
)

type privacyPlanningDispatch struct {
	frame                   protocol.InferenceRequestMessage
	body                    []byte
	provider                string
	participates, telemetry bool
	deadline                time.Time
	budget                  int64
}

type privacyPlanningHTTPResult struct {
	status int
	body   []byte
	err    error
}

type privacyPlanningFixture struct {
	ctx        context.Context
	cancel     context.CancelFunc
	reg        *registry.Registry
	store      *memory.MemoryStore
	server     *serverFixture
	http       *httptest.Server
	client     *http.Client
	planning   *cachePlanningUDSFixture
	proxy      *privacyPlanProxy
	providers  []*failoverProvider
	capability protocol.PrefixCacheV2Capability
	keys       map[string]string
	records    chan privacyPlanningDispatch
	failNext   atomic.Bool
	mu         sync.Mutex
	owned      []*registry.PendingRequest
}

func newPrivacyPlanningFixture(t *testing.T, providers int) *privacyPlanningFixture {
	t.Helper()
	binary := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR")
	if binary == "" {
		t.Skip("requires the source-bound actual candidate Rust service")
	}
	if os.Getenv("DARKBLOOM_TEST_PROMPT_GO_VERSION") != "candidate" {
		t.Fatal("joint fixture requires the bound candidate Go composition")
	}
	digest := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR_SHA256")
	cachePlanningVerifyRealBinary(t, binary, digest)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	reg, st, server, transport := setupTTFTFailoverServerWithConfig(t, TestServerConfig{
		ServiceReservations: true, FirstContentSLAAccounts: []string{privacyPlanningAccountA, privacyPlanningAccountB},
		FirstContentDeadlineBase: 3 * time.Second,
	})
	f := &privacyPlanningFixture{ctx: ctx, cancel: cancel, reg: reg, store: st, server: server,
		http: transport, keys: make(map[string]string), records: make(chan privacyPlanningDispatch, 16)}
	t.Cleanup(func() {
		cancel()
		for _, provider := range f.providers {
			provider.close()
			select {
			case <-provider.done:
			case <-time.After(5 * time.Second):
				t.Error("joint provider did not drain")
			}
		}
		f.forgetOwned(t)
		if f.client != nil {
			f.client.CloseIdleConnections()
		}
		server.Close()
		cachePlanningVerifyRealBinary(t, binary, digest)
	})
	server.bindBilling(billing.NewService(st, server.ledger, quietLogger(), billing.Config{MockMode: true}))
	for _, account := range []string{privacyPlanningAccountA, privacyPlanningAccountB} {
		if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:fixture:" + account, Role: store.RoleService}); err != nil {
			t.Fatal(err)
		}
		key, err := st.CreateKeyForAccount(account)
		if err != nil {
			t.Fatal(err)
		}
		f.keys[account] = key
		if err := st.Credit(account, conformance.InitialBalanceMicroUSD, store.LedgerDeposit, "joint-fixture"); err != nil {
			t.Fatal(err)
		}
	}
	artifact := cachePlanningRealArtifactFor(t, "joint-cache-model", false)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: artifact.manifest.ModelID, InputPrice: 50_000, OutputPrice: 200_000}); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for index := 0; index < providers; index++ {
		provider := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
			Name: fmt.Sprintf("joint-provider-%d", index), Version: "0.8.15", DecodeTPS: 1000,
			Models: []failoverModelSpec{{ID: artifact.manifest.ModelID}},
			Script: func(ctx context.Context, fp *failoverProvider, frame protocol.InferenceRequestMessage, body []byte) {
				p := reg.GetProvider(fp.registryID)
				if p == nil {
					t.Error("provider disappeared before observation")
					return
				}
				pending := p.GetPending(frame.RequestID)
				if pending == nil {
					t.Error("inference frame has no live pending owner")
					return
				}
				f.remember(pending)
				observation := privacyPlanningDispatch{frame: frame, body: append([]byte(nil), body...),
					provider: fp.registryID, participates: pending.CacheRoutingParticipates(),
					telemetry: pending.CacheRoutingTelemetryEligible(), deadline: pending.FirstContentDeadline,
					budget: pending.FirstContentBudgetMS}
				select {
				case f.records <- observation:
				case <-ctx.Done():
					return
				}
				if f.failNext.CompareAndSwap(true, false) {
					fp.sendInferenceError(ctx, frame, "synthetic pre-content error", http.StatusInternalServerError)
					return
				}
				fp.sendRoleChunk(ctx, frame, artifact.manifest.ModelID)
				fp.sendContentChunk(ctx, frame, artifact.manifest.ModelID, privacyPlanningMarker)
				fp.sendComplete(ctx, frame, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 10})
			},
		})
		f.providers = append(f.providers, provider)
		ids = append(ids, provider.registryID)
		setPrefixCacheProtocol(t, reg, provider, 1)
	}
	f.planning = newCachePlanningUDSFixtureWithOptions(t, server.Owner, server.registry, cachePlanningFixtureOptions{
		realSidecar: &cachePlanningRealSidecarOptions{binary: binary, sha256: digest,
			artifacts: []cachePlanningRealArtifact{artifact}},
	}, ids...)
	f.planning.waitReady(t)
	f.capability = cacheEligibilityV2Capability(f.planning.model)
	f.capability.ModelAggregateHash, f.capability.PromptContractID = f.planning.aggregate, f.planning.contract
	f.capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	for _, provider := range f.providers {
		if err := reg.UpdatePrefixCacheCapabilities(provider.registryID, 2, []protocol.PrefixCacheV2Capability{f.capability}); err != nil {
			t.Fatal(err)
		}
	}
	f.proxy = newPrivacyPlanProxy(t, f.planning.control)
	server.SetPromptContractClient(f.proxy.client)
	f.client = conformance.LoopbackClient(t, transport.URL)
	// On fatal paths, cancel providers and real/proxy requests before owner joins.
	t.Cleanup(cancel)
	return f
}

func (f *privacyPlanningFixture) remember(request *registry.PendingRequest) {
	f.mu.Lock()
	f.owned = append(f.owned, request)
	f.mu.Unlock()
}

func (f *privacyPlanningFixture) forgetOwned(t *testing.T) {
	t.Helper()
	f.mu.Lock()
	owned := f.owned
	f.owned = nil
	f.mu.Unlock()
	for _, request := range owned {
		f.reg.ForgetCacheAttempt(request)
		f.reg.ForgetCacheAttempt(request)
	}
	if _, attempts := f.reg.CacheRoutingStateCounts(); attempts != 0 {
		t.Errorf("owned attempts remain after explicit double-forget: %d", attempts)
	}
}

// outstandingHold measures the account's unreleased service hold at the
// reservation controller this fixture's runtime was composed with. A reading
// briefly reserves and releases probe amounts for the account: take it only
// while no request for that account is being admitted, and evaluate it last in
// a polled predicate.
func (f *privacyPlanningFixture) outstandingHold(t *testing.T, account string) int64 {
	t.Helper()
	return conformance.OutstandingServiceHold(t, f.server.reservations, f.store, account)
}

func (f *privacyPlanningFixture) start(t *testing.T, account, endpoint, body string, route ...string) (<-chan privacyPlanningHTTPResult, context.CancelFunc) {
	t.Helper()
	ctx, cancel := privacyPlanRequestContext(f.ctx)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, f.http.URL+endpoint, strings.NewReader(body))
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+f.keys[account])
	request.Header.Set("Content-Type", "application/json")
	if len(route) > 0 {
		request.Header.Set("X-Darkbloom-Route", route[0])
	}
	done := make(chan privacyPlanningHTTPResult, 1)
	go func() {
		response, err := f.client.Do(request)
		if err != nil {
			done <- privacyPlanningHTTPResult{err: err}
			return
		}
		defer response.Body.Close()
		body, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
		if len(body) > 1<<20 {
			err = fmt.Errorf("joint response exceeded its bound")
		}
		done <- privacyPlanningHTTPResult{status: response.StatusCode, body: body, err: err}
	}()
	return done, cancel
}

func (f *privacyPlanningFixture) finish(t *testing.T, done <-chan privacyPlanningHTTPResult) privacyPlanningHTTPResult {
	t.Helper()
	select {
	case result := <-done:
		return result
	case <-f.ctx.Done():
		t.Fatal("joint HTTP request did not terminate")
		return privacyPlanningHTTPResult{}
	}
}

func privacyPlanningBody(t *testing.T, model, endpoint string, stream bool, caller string) string {
	t.Helper()
	input := strings.ReplaceAll(cachePlanningEndpointBody(model, endpoint, stream), "planning lifecycle fixture",
		strings.Repeat("hello ", 300)+privacyPlanningContent)
	var body map[string]any
	if err := json.Unmarshal([]byte(input), &body); err != nil {
		t.Fatal(err)
	}
	body["user"] = caller
	body["metadata"] = map[string]any{"conversation_id": "must-not-forward", "account_id": caller}
	body["cache_control"] = map[string]any{"type": "ephemeral", "metadata": map[string]any{"user": "nested-cache-value"}}
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func assertPrivacyPlanningBody(t *testing.T, body []byte) {
	t.Helper()
	if err := privacyPlanningBodyError(body); err != nil {
		t.Fatal(err)
	}
}

func privacyPlanningBodyError(body []byte) error {
	var object map[string]any
	if err := json.Unmarshal(body, &object); err != nil {
		return err
	}
	for _, key := range []string{"user", "metadata"} {
		if _, exists := object[key]; exists {
			return fmt.Errorf("caller identity field %s reached planning/provider", key)
		}
	}
	control, _ := object["cache_control"].(map[string]any)
	nested, _ := control["metadata"].(map[string]any)
	if control["type"] != "ephemeral" || nested["user"] != "nested-cache-value" {
		return fmt.Errorf("nested cache-control semantics were not preserved")
	}
	if !bytes.Contains(body, []byte("nested-user-value")) || !bytes.Contains(body, []byte("nested-metadata-value")) ||
		!bytes.Contains(body, []byte("nested-cache-value")) || bytes.Contains(body, []byte("must-not-forward")) {
		return fmt.Errorf("semantic nested value lost or caller metadata retained")
	}
	return nil
}
