package api

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
	if err := reg.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: registry.CacheRoutingOn, ActivationPct: 100,
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
	return result.Plan
}
