package inference_test

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Exercise admission after optional planning has produced exact work and
// consumed the shorter fallback clock. The HTTP handler and live in-memory
// registry are real; the original clocks are explicit to avoid timing sleeps.
func TestFirstContentPreflightExpiredServingCutoffKeepsDeadlineCause(t *testing.T) {
	for _, hard := range []bool{false, true} {
		for _, aliasCase := range []string{"none", "qualified", "unqualified", "none-busy", "qualified-busy", "unqualified-busy"} {
			t.Run(fmt.Sprintf("hard%t/alias%s", hard, aliasCase), func(t *testing.T) {
				alias := strings.TrimSuffix(aliasCase, "-busy")
				busy := alias != aliasCase
				s, _ := testServer(t)
				t.Cleanup(s.Close)
				s.SetTTFTHardReject(hard)
				const desired, previous, publicAlias = "expired-desired", "expired-previous", "expired-alias"
				artifact, contract := strings.Repeat("a", 64), strings.Repeat("b", 64)
				s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: desired, SizeGB: 1, MinRAMGB: 24, WeightHash: artifact}, {ID: previous, SizeGB: 1, MinRAMGB: 24, WeightHash: artifact}})
				legacy := registerBuildsProvider(s, "expired-legacy", desired)
				legacy.Mu().Lock()
				legacy.Models[0].WeightHash = artifact
				legacy.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: desired, State: "idle", MaxConcurrency: 8, ActiveTokenBudgetMax: 200_000}}}
				legacy.Mu().Unlock()
				// A physically fitting but expired peer must not disappear into a
				// permanent model-too-large classification because of this peer.
				tooSmall := registerBuildsProvider(s, "expired-too-small", desired)
				tooSmall.Mu().Lock()
				tooSmall.Hardware.MemoryGB = 8
				tooSmall.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 8,
					Slots: []protocol.BackendSlotCapacity{{Model: desired, State: "unknown", MaxConcurrency: 8, ActiveTokenBudgetMax: 200_000}}}
				tooSmall.Mu().Unlock()
				if busy {
					saturated := registerBuildsProvider(s, "expired-saturated", desired)
					saturated.Mu().Lock()
					saturated.Models[0].WeightHash = artifact
					saturated.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64,
						Slots: []protocol.BackendSlotCapacity{{Model: desired, State: "running", MaxConcurrency: 1, ActiveTokenBudgetMax: 200_000}}}
					saturated.Mu().Unlock()
					saturated.AddPending(&registry.PendingRequest{RequestID: "saturated-request", Model: desired})
					t.Cleanup(func() { saturated.RemovePending("saturated-request") })
				}
				public := desired
				if alias != "none" {
					public = publicAlias
					s.registry.SetModelAliases(map[string]registry.AliasTarget{public: {Desired: desired, Previous: previous}})
					matching := registerBuildsProvider(s, "expired-alias-matching", previous)
					matching.Mu().Lock()
					matching.Models[0].WeightHash = artifact
					matching.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: previous, State: "idle", MaxConcurrency: 8, ActiveTokenBudgetMax: 200_000,
						PromptWorkIdentity: &protocol.PromptWorkIdentity{ModelArtifactHash: artifact, PromptContractID: contract}}}}
					if alias == "unqualified" {
						matching.BackendCapacity.Slots[0].PromptWorkIdentity = nil
					}
					matching.Mu().Unlock()
				}
				received := time.Now().Add(-1500 * time.Millisecond)
				work := &protocol.PromptWork{Version: protocol.PromptWorkVersion, Source: protocol.PromptWorkExact,
					PromptTokens: 1200, UpperBoundTokens: 1200, ModelArtifactHash: artifact, PromptContractID: contract}
				params := inference.AdmissionRequest{Model: desired, PublicModel: public, EstimatedPromptTokens: 500, RequestedMaxTokens: 32,
					ReceivedAt: received, Deadline: 3 * time.Second, FallbackDeadline: time.Second,
					PromptWorkForModel: func(string) *protocol.PromptWork { return work },
					DeadlineForWork:    func(string, *protocol.PromptWork) time.Duration { return 3 * time.Second }}
				query := (firstcontent.Preflight{Calibration: estimate.NewContextCalibration(), ReceivedAt: params.ReceivedAt, Deadline: params.Deadline, FallbackDeadline: params.FallbackDeadline,
					PromptWorkForModel: params.PromptWorkForModel, DeadlineForWork: params.DeadlineForWork}).Request(desired, registry.RequestTraits{})
				if !query.FirstContentDeadline.After(time.Now()) || query.FirstContentFallbackDeadline.After(time.Now()) ||
					query.FirstContentDeadlineForIdentity("", "").After(time.Now()) {
					t.Fatal("fixture did not retain a live exact envelope and expired legacy cutoff")
				}
				var spills, refunds atomic.Int64
				params.RefundReservation = func() { refunds.Add(1) }
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					parsed := map[string]any{"model": desired}
					result := s.NewAdmission().Run(w, r, parsed, params)
					if !result.Handled {
						spills.Add(1)
						httpx.WriteJSON(w, http.StatusOK, map[string]string{"model": result.Model})
					}
				}))
				t.Cleanup(server.Close)
				response, err := server.Client().Get(server.URL)
				if err != nil {
					t.Fatal(err)
				}
				defer response.Body.Close()
				body, _ := io.ReadAll(response.Body)
				if alias == "qualified" {
					if response.StatusCode != http.StatusOK || !strings.Contains(string(body), previous) || spills.Load() != 1 || refunds.Load() != 0 {
						t.Fatalf("live qualified alias failed: HTTP%d body%s spills%d refunds%d", response.StatusCode, body, spills.Load(), refunds.Load())
					}
				} else {
					if response.StatusCode != http.StatusTooManyRequests || !strings.Contains(string(body), "deadline has expired") || response.Header.Get("Retry-After") == "" || spills.Load() != 0 || refunds.Load() != 1 {
						t.Fatalf("expired renderer lost deadline cause or spilled: HTTP%d body%s spills%d refunds%d", response.StatusCode, body, spills.Load(), refunds.Load())
					}
					waitForRejectionCount(t, s, 1)
					if records := s.store.RejectionRecordsSince(time.Time{}); len(records) != 1 || records[0].ReasonCode != failure.ErrorReasonDeadlineUnreachable || records[0].Stage != "routing_ttft" {
						t.Fatalf("expiry lost its non-provider-fault ledger cause: %+v", records)
					}
				}
			})
		}
	}
}

func TestFirstContentPreflightNoFittingPeerRemainsModelUnavailable(t *testing.T) {
	s, _ := testServer(t)
	t.Cleanup(s.Close)
	const model = "permanently-too-large"
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	p := registerBuildsProvider(s, "too-small-only", model)
	p.Mu().Lock()
	p.Hardware.MemoryGB = 8
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 8, Slots: []protocol.BackendSlotCapacity{{Model: model, State: "unknown"}}}
	p.Mu().Unlock()
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	var refunds atomic.Int64
	result := s.NewAdmission().Run(w, r, map[string]any{"model": model}, inference.AdmissionRequest{
		Model: model, PublicModel: model, EstimatedPromptTokens: 500, RequestedMaxTokens: 32,
		ReceivedAt: time.Now(), Deadline: 3 * time.Second, FallbackDeadline: time.Second,
		DeadlineForWork:   func(string, *protocol.PromptWork) time.Duration { return 3 * time.Second },
		RefundReservation: func() { refunds.Add(1) },
	})
	if !result.Handled || w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "too large") || refunds.Load() != 1 {
		t.Fatalf("permanent physical rejection changed: handled%t HTTP%d body%s refunds%d", result.Handled, w.Code, w.Body.String(), refunds.Load())
	}
}
