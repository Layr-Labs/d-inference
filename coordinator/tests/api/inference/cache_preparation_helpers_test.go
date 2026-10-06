package inference_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func configureCachePreparationTest(t testing.TB, reg *registry.Registry) {
	t.Helper()
	configureCacheFirstSightTest(t, reg, 0)
}

// A minimum of 0 leaves first sight off, as a configuration literal does.
func configureCacheFirstSightTest(t testing.TB, reg *registry.Registry, firstSightMinTokens int) {
	t.Helper()
	if err := reg.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: registry.CacheRoutingOn, ActivationPct: 100, FirstSightMinTokens: firstSightMinTokens,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
}

// Cross-package tests obtain genuine generation-bound plans through the public
// planner. Only the local sidecar response is synthetic.
func cachePreparationPlanForTest(t testing.TB, reg *registry.Registry, capability protocol.PrefixCacheV2Capability) registry.CachePlan {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "cache-api-plan-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	socket := filepath.Join(root, "sidecar.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hash := strings.Repeat("c", 64)
		boundaries := make([]promptcontract.Boundary, 16)
		for i := range boundaries {
			boundaries[i] = promptcontract.Boundary{TokenCount: uint32(i+1) * promptcontract.BlockSize, ChainHash: hash}
		}
		_ = json.NewEncoder(w).Encode(promptcontract.Plan{
			PromptContractID: capability.PromptContractID, PromptTokenCount: 4097,
			BlockBoundaries:       boundaries,
			LastCompleteBlockHash: &hash,
		})
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	client := promptcontract.NewClient(promptcontract.ClientConfig{SocketPath: socket, RequestTimeout: time.Second})
	t.Cleanup(client.Close)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: capability.ModelID, WeightHash: capability.ModelAggregateHash}})
	result := reg.PlanCacheRouteWithResult(context.Background(), client, registry.CachePlanInput{
		Account: "account", Model: capability.ModelID, ModelAggregateSHA256: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, Body: []byte(`{"messages":[]}`),
	})
	if result.Outcome != registry.CachePlanPlanned {
		t.Fatalf("test sidecar plan failed: %s", result.Outcome)
	}
	if result.PromptWork == nil || result.PromptWork.PromptTokens != 4097 || !result.PromptWork.IsQualifiedFor(capability.ModelAggregateHash, capability.PromptContractID) {
		t.Fatal("validated cache plan lost reusable exact prompt accounting")
	}
	return result.Plan
}

func preparedCacheAttemptForTest(t testing.TB) (*registry.Registry, *registry.Provider, *registry.PendingRequest) {
	t.Helper()
	return preparedFirstSightCacheAttemptForTest(t, 0)
}

// The planned prompt holds 4,097 tokens, so with first sight on from one
// stride its first plan names the boundary at 4,096.
func preparedFirstSightCacheAttemptForTest(t testing.TB, firstSightMinTokens int) (*registry.Registry, *registry.Provider, *registry.PendingRequest) {
	t.Helper()
	reg := registry.New(quietLogger())
	configureCacheFirstSightTest(t, reg, firstSightMinTokens)
	capability := cacheEligibilityV2Capability("model")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, PrefixCacheProtocol: 2,
		Models:              []protocol.ModelInfo{{ID: capability.ModelID, WeightHash: capability.ModelAggregateHash}},
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	pending := &registry.PendingRequest{RequestID: "request", Model: "model",
		CachePlan: cachePreparationPlanForTest(t, reg, capability)}
	if err := reg.PrepareCacheAttempt(pending, provider); err != nil {
		t.Fatal(err)
	}
	if !pending.CacheRoutingParticipates() {
		t.Fatal("valid registered provider and sidecar plan did not prepare")
	}
	t.Cleanup(func() { reg.ForgetCacheAttempt(pending) })
	return reg, provider, pending
}
