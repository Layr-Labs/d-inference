package registry_test

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	cacheplan "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePlanRevalidatesGenerationAfterSidecar(t *testing.T) {
	for _, change := range []string{"none", "reconfigure", "off", "cancel"} {
		t.Run(change, func(t *testing.T) {
			var generation *cacheplan.Generation
			r, _, _ := exactTestRegistry(t, production.Dependencies{Cache: production.CacheDependencies{Generations: func() *cacheplan.Generation {
				generation = &cacheplan.Generation{}
				return generation
			}}})
			r.SetModelCatalog([]production.CatalogEntry{{ID: "model", WeightHash: strings.Repeat("a", 64)}})
			temp, err := os.MkdirTemp("/tmp", "cache-plan-generation-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.RemoveAll(temp) })
			socket := filepath.Join(temp, "sidecar.sock")
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(socket, 0o600); err != nil {
				t.Fatal(err)
			}
			started, release := make(chan struct{}), make(chan struct{})
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				close(started)
				select {
				case <-release:
				case <-request.Context().Done():
					return
				}
				hash := strings.Repeat("c", 64)
				_ = json.NewEncoder(w).Encode(promptcontract.Plan{PromptContractID: strings.Repeat("b", 64), PromptTokenCount: 257,
					BlockBoundaries: []promptcontract.Boundary{{TokenCount: 256, ChainHash: hash}}, LastCompleteBlockHash: &hash})
			})}
			go func() { _ = server.Serve(listener) }()
			t.Cleanup(func() { _ = server.Close() })
			client := promptcontract.NewClient(promptcontract.ClientConfig{SocketPath: socket, RequestTimeout: 2 * time.Second})
			t.Cleanup(client.Close)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			results := make(chan production.CachePlanResult, 1)
			go func() {
				results <- r.PlanCacheRouteWithResult(ctx, client, production.CachePlanInput{Account: "account", Model: "model", PromptContractID: strings.Repeat("b", 64), ModelAggregateSHA256: strings.Repeat("a", 64), Body: []byte(`{"messages":[]}`)})
			}()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("sidecar not reached")
			}
			// Configuration must complete while sidecar IO is blocked: no registry
			// or retired-tracker lock may be carried across the planner call.
			if change == "reconfigure" || change == "off" {
				configured := make(chan error, 1)
				mode := production.CacheRoutingOn
				if change == "off" {
					mode = production.CacheRoutingOff
				}
				go func() { configured <- r.ConfigureCacheRouting(generationTestConfig(mode)) }()
				select {
				case err := <-configured:
					if err != nil {
						t.Fatal(err)
					}
				case <-time.After(time.Second):
					t.Fatal("configuration blocked behind sidecar IO")
				}
			}
			if change == "cancel" {
				// Keep the successful response blocked until cancellation returns;
				// releasing it now races the transport's cancellation observer.
				defer close(release)
				cancel()
			} else {
				close(release)
			}
			var result production.CachePlanResult
			select {
			case result = <-results:
			case <-time.After(3 * time.Second):
				t.Fatal("planner failed to return")
			}
			expected := map[string]cacheactivation.CachePlanOutcome{"none": cacheactivation.CachePlanPlanned, "reconfigure": cacheactivation.CachePlanIneligible, "off": cacheactivation.CachePlanOff, "cancel": cacheactivation.CachePlanSidecarError}[change]
			if result.Outcome != expected || !result.SidecarCalled {
				t.Fatalf("outcome=%s called=%t want=%s", result.Outcome, result.SidecarCalled, expected)
			}
			if change == "none" {
				if !(&production.PendingRequest{CachePlan: result.Plan}).CacheRoutingTelemetryEligible() || !result.Plan.Authenticates(generation) {
					t.Fatal("valid sidecar result lacks current provenance")
				}
			} else if (&production.PendingRequest{CachePlan: result.Plan}).CacheRoutingTelemetryEligible() || result.Plan.CacheScope != "" || result.Plan.HasOrigin() {
				t.Fatal("stale/failed plan exposed route scope")
			}
		})
	}
}
