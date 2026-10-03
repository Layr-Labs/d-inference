package inference

import (
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestHandleInferenceErrorPreservesModelLoadCategories(t *testing.T) {
	cases := []struct {
		name         string
		failureCode  protocol.InferenceFailureCode
		statusCode   int
		wantFailures int
	}{
		{"missing model", protocol.FailureCodeModelUnavailable, http.StatusNotFound, 0},
		{"transient load pressure", protocol.FailureCodeCapacity, http.StatusServiceUnavailable, 0},
		{"genuine provider load fault", protocol.FailureCodeInternalFailure, http.StatusInternalServerError, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
			reg := registry.New(logger)
			srv := newComposedServer(reg, memory.NewMemory(store.Config{AdminKey: "test-key"}), TestServerConfig{}, logger)
			model := "load-category-model"
			provider := registerBuildsProvider(srv, "provider-"+tc.name, model)

			pending := &registry.PendingRequest{
				RequestID:          "req-load-category",
				Model:              model,
				RequestedMaxTokens: 128,
				ChunkCh:            make(chan registry.ProviderChunk, 1),
				CompleteCh:         make(chan protocol.UsageInfo, 1),
				ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
			}
			selected, _ := reg.ReserveProviderEx(model, pending)
			if selected == nil || selected.ID != provider.ID {
				t.Fatal("routable provider fixture was not selected before the load failure")
			}

			srv.HandleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   pending.RequestID,
				Error:       "UNTRUSTED_LOAD_DETAIL",
				StatusCode:  tc.statusCode,
				ErrorReason: errorReasonModelLoad,
				FailureCode: tc.failureCode,
			})

			select {
			case delivered := <-pending.ErrorCh:
				if delivered.FailureCode != tc.failureCode ||
					delivered.StatusCode != tc.statusCode ||
					delivered.ErrorReason != errorReasonModelLoad {
					t.Fatalf("delivered load failure = %+v, want code=%q status=%d reason=%q",
						delivered, tc.failureCode, tc.statusCode, errorReasonModelLoad)
				}
			default:
				t.Fatal("model-load terminal was not delivered")
			}
			if got := provider.Reputation.FailedJobs; got != tc.wantFailures {
				t.Fatalf("FailedJobs = %d, want %d", got, tc.wantFailures)
			}
			if got := provider.Reputation.TotalJobs; got != tc.wantFailures {
				t.Fatalf("TotalJobs = %d, want %d", got, tc.wantFailures)
			}

			coolingRequest := &registry.PendingRequest{
				RequestID: "req-load-category-cooling",
				Model:     model, RequestedMaxTokens: 128,
			}
			if selected, _ := reg.ReserveProviderEx(model, coolingRequest); selected != nil {
				t.Fatal("provider/model pair remained routable during its load-failure cooldown")
			}
			reg.ClearDispatchLoadCooldown(provider.ID, model)
			recoveredRequest := &registry.PendingRequest{
				RequestID: "req-load-category-recovered",
				Model:     model, RequestedMaxTokens: 128,
			}
			if selected, _ := reg.ReserveProviderEx(model, recoveredRequest); selected == nil {
				t.Fatal("provider did not become routable after clearing the load-failure cooldown")
			} else {
				selected.RemovePending(recoveredRequest.RequestID)
			}
		})
	}
}
