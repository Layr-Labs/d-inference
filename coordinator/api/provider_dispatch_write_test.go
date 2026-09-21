package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

const dispatchAccountingModel = "write-accounting-model"

func dispatchAccountingProvider(t *testing.T) (*Server, *registry.Provider, *websocket.Conn) {
	t.Helper()
	srv, _ := testServer(t)
	t.Cleanup(srv.Close)
	accepted := make(chan *websocket.Conn, 1)
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		accepted <- conn
	}))
	t.Cleanup(httpServer.Close)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	peer, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpServer.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = peer.CloseNow() })
	conn := <-accepted
	keys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: dispatchAccountingModel}})
	p := srv.registry.Register("write-accounting-provider", conn, &protocol.RegisterMessage{
		Backend: registry.BackendMLXSwift, PublicKey: base64.StdEncoding.EncodeToString(keys.PublicKey[:]), EncryptedResponseChunks: true,
		Hardware:            protocol.Hardware{MemoryGB: 64, MemoryAvailableGB: 60},
		Models:              []protocol.ModelInfo{{ID: dispatchAccountingModel, ModelType: "chat", SizeBytes: 1}},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.Mu().Unlock()
	p.CompleteProviderStateRestore()
	t.Cleanup(func() { srv.registry.Disconnect(p.ID) })
	return srv, p, peer
}

func assertDispatchAccountingFrame(t *testing.T, p *registry.Provider, peer *websocket.Conn, dispatched bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := p.WriteTextControl(ctx, []byte(`{"type":"accounting_barrier"}`)); err != nil {
		t.Fatal(err)
	}
	_, data, err := peer.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var frame struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(data, &frame); err != nil {
		t.Fatal(err)
	}
	if dispatched {
		if frame.Type != protocol.TypeInferenceRequest {
			t.Fatalf("expected inference frame, got %s", data)
		}
		_, data, err = peer.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatal(err)
		}
	}
	if frame.Type != "accounting_barrier" {
		t.Fatalf("unauthorized or extra inference reached socket: %s", data)
	}
}

func TestPrimaryDispatchAccountingExcludesAuthorizationRejectedFrame(t *testing.T) {
	for _, deny := range []bool{false, true} {
		t.Run(map[bool]string{false: "committed", true: "rejected"}[deny], func(t *testing.T) {
			s, p, peer := dispatchAccountingProvider(t)
			timing := &registry.RequestTiming{ReceivedAt: time.Now()}
			profile := registry.NewRequestProfile(timing.ReceivedAt, "request", nil, time.Second)
			d := &dispatchState{}
			var attempted *registry.PendingRequest
			reserver := func(pr *registry.PendingRequest, excluded []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
				attempted = pr
				selected, decision := s.registry.ReserveProviderEx(dispatchAccountingModel, pr, excluded...)
				if selected != p {
					t.Fatal("positive-control reservation failed")
				}
				if deny {
					s.registry.MarkUntrusted(p.ID)
				}
				return selected, decision, nil
			}
			r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
			provider, _, _, _, lastErr, _ := s.dispatchWithReserver(r, dispatchAccountingModel, dispatchAccountingModel, []byte(`{"model":"write-accounting-model","messages":[{"role":"user","content":"test"}]}`), "test-key", nil, 0, 1, 5*time.Second, 16, registry.TokenAdmission{}, false, registry.RequestTraits{}, nil, false, selfRoutePolicy{}, timing, false, registry.CachePlan{}, map[string]struct{}{}, 0, profile, "", nil, d.noteProviderDispatched, false, reserver)
			if deny {
				if provider != nil || lastErr == "" || d.providerDispatches != 0 || !timing.DispatchedAt.IsZero() || profile.DispatchedAttempts() != 0 {
					t.Fatalf("unsent frame counted: provider=%v err=%s count=%d timing=%v attempts=%d", provider, lastErr, d.providerDispatches, timing.DispatchedAt, profile.DispatchedAttempts())
				}
			} else if provider != p || lastErr != "" || d.providerDispatches != 1 || timing.DispatchedAt.IsZero() || profile.DispatchedAttempts() != 1 {
				t.Fatalf("committed accounting lost: err=%s count=%d attempts=%d", lastErr, d.providerDispatches, profile.DispatchedAttempts())
			}
			if attempted == nil {
				t.Fatal("reserver not reached")
			}
			if deny && d.exhaustionAttemptCount() != 1 {
				t.Fatal("all-unsent case lost intentional loop-attempt fallback")
			}
			if (attempted.Profile.WriteDequeuedUS.Load() == 0) != deny {
				t.Fatal("primary dequeue stamp did not match authorization")
			}
			assertDispatchAccountingFrame(t, p, peer, !deny)
		})
	}
}

func TestQueuedDispatchAccountingExcludesAuthorizationRejectedFrame(t *testing.T) {
	for _, deny := range []bool{false, true} {
		t.Run(map[bool]string{false: "committed", true: "rejected"}[deny], func(t *testing.T) {
			s, p, peer := dispatchAccountingProvider(t)
			timing := &registry.RequestTiming{ReceivedAt: time.Now()}
			profile := registry.NewRequestProfile(timing.ReceivedAt, "queued-request", nil, time.Second)
			pending := &registry.PendingRequest{RequestID: "queued-request", Model: dispatchAccountingModel, Timing: timing, Profile: profile.NewAttempt("queued-request", 0, "")}
			if s.registry.ReserveProvider(dispatchAccountingModel, pending) != p {
				t.Fatal("positive-control reservation failed")
			}
			d := &dispatchState{s: s, provider: p, pr: pending, timing: timing}
			builder := providerInferenceFrameBuilder(pending.RequestID, "ephemeral", "ciphertext", pending)
			metadata, err := d.writeQueuedProviderInferenceRequest(context.Background(), func(at time.Time) ([]byte, error) {
				if deny {
					s.registry.MarkUntrusted(p.ID)
				}
				return builder(at)
			})
			if deny {
				if err == nil || metadata.Committed || d.providerDispatches != 0 || !timing.DispatchedAt.IsZero() || profile.DispatchedAttempts() != 0 {
					t.Fatalf("rejected queued frame counted: err=%v metadata=%+v count=%d timing=%v attempts=%d", err, metadata, d.providerDispatches, timing.DispatchedAt, profile.DispatchedAttempts())
				}
			} else if err != nil || !metadata.Committed || d.providerDispatches != 1 || timing.DispatchedAt.IsZero() || pending.Profile.WriteDequeuedUS.Load() == 0 {
				t.Fatalf("queued commitment lost: err=%v count=%d attempts=%d", err, d.providerDispatches, profile.DispatchedAttempts())
			}
			if (pending.Profile.WriteDequeuedUS.Load() == 0) != deny {
				t.Fatal("queued dequeue stamp did not match authorization")
			}
			if deny && d.exhaustionAttemptCount() != 1 {
				t.Fatal("all-unsent queue case lost intentional loop-attempt fallback")
			}
			assertDispatchAccountingFrame(t, p, peer, !deny)
		})
	}
}

func TestUnauthorizedRetryDoesNotIncreasePreviouslyCommittedExhaustionCount(t *testing.T) {
	for _, funnel := range []string{"primary", "queued"} {
		t.Run(funnel, func(t *testing.T) {
			s, p, peer := dispatchAccountingProvider(t)
			first := &registry.PendingRequest{RequestID: "first-committed", Model: dispatchAccountingModel, Timing: &registry.RequestTiming{ReceivedAt: time.Now()}}
			if s.registry.ReserveProvider(dispatchAccountingModel, first) != p {
				t.Fatal("first reserve")
			}
			d := &dispatchState{s: s, provider: p, pr: first, timing: first.Timing}
			if metadata, err := d.writeQueuedProviderInferenceRequest(context.Background(), providerInferenceFrameBuilder(first.RequestID, "ephemeral", "ciphertext", first)); err != nil || !metadata.Committed {
				t.Fatalf("first write: metadata=%+v err=%v", metadata, err)
			}
			assertDispatchAccountingFrame(t, p, peer, true)
			p.RemovePending(first.RequestID)
			s.registry.SetProviderIdle(p.ID)
			d.attempt = 4 // More selection/retry loops must not inflate actual sends.
			timing := &registry.RequestTiming{ReceivedAt: time.Now()}
			if funnel == "primary" {
				reserver := func(pr *registry.PendingRequest, excluded []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
					selected, decision := s.registry.ReserveProviderEx(dispatchAccountingModel, pr, excluded...)
					if selected != p {
						t.Fatal("retry reserve")
					}
					s.registry.MarkUntrusted(p.ID)
					return selected, decision, nil
				}
				r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
				provider, _, _, _, lastErr, _ := s.dispatchWithReserver(r, dispatchAccountingModel, dispatchAccountingModel, []byte(`{"model":"write-accounting-model"}`), "test-key", nil, 0, 1, 5*time.Second, 16, registry.TokenAdmission{}, false, registry.RequestTraits{}, nil, false, selfRoutePolicy{}, timing, false, registry.CachePlan{}, map[string]struct{}{}, 1, nil, "", nil, d.noteProviderDispatched, false, reserver)
				if provider != nil || lastErr == "" {
					t.Fatal("retry was not denied")
				}
			} else {
				pending := &registry.PendingRequest{RequestID: "queued-denied", Model: dispatchAccountingModel, Timing: timing}
				if s.registry.ReserveProvider(dispatchAccountingModel, pending) != p {
					t.Fatal("queued retry reserve")
				}
				d.pr, d.timing = pending, timing
				builder := providerInferenceFrameBuilder(pending.RequestID, "ephemeral", "ciphertext", pending)
				if metadata, err := d.writeQueuedProviderInferenceRequest(context.Background(), func(at time.Time) ([]byte, error) { s.registry.MarkUntrusted(p.ID); return builder(at) }); err == nil || metadata.Committed {
					t.Fatal("queued retry was not denied")
				}
			}
			if d.providerDispatches != 1 || d.exhaustionAttemptCount() != 1 || !timing.DispatchedAt.IsZero() {
				t.Fatalf("unauthorized retry inflated count: actual=%d reported=%d timing=%v", d.providerDispatches, d.exhaustionAttemptCount(), timing.DispatchedAt)
			}
			assertDispatchAccountingFrame(t, p, peer, false)
		})
	}
}

func TestQueuedAppAttestExpiryOrRevocationDoesNotPublishDispatch(t *testing.T) {
	for _, reason := range []string{"expired", "revoked", "build_revoked"} {
		t.Run(reason, func(t *testing.T) {
			s, p, peer := dispatchAccountingProvider(t)
			p.Mu().Lock()
			p.AccountID = "account"
			p.Hardware.MachineModel = "Mac15,8"
			p.TrustLevel = registry.TrustNone
			p.ChallengeVerifiedSIP = false
			p.Mu().Unlock()
			s.registry.SetAppAttestServingPolicy(true, 7)
			if !s.registry.BindVerifiedMachineIdentity(p, "account", "machine") {
				t.Fatal("identity")
			}
			now := time.Now()
			lease := registry.AppAttestServingAuthorization{AccountID: "account", MachineID: "machine", CredentialID: "credential", ConnectionID: p.ID, Endpoint: p.PublicKey, PolicyGeneration: 7, IssuedAt: now, ValidUntil: now.Add(75 * time.Millisecond), MachineModel: "Mac15,8", MemoryGB: 64}
			if !s.registry.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant")
			}
			timing := &registry.RequestTiming{ReceivedAt: now}
			profile := registry.NewRequestProfile(now, "lease-race", nil, time.Second)
			pending := &registry.PendingRequest{RequestID: "lease-race", Model: dispatchAccountingModel, Timing: timing, Profile: profile.NewAttempt("lease-race", 0, "")}
			if s.registry.ReserveProvider(dispatchAccountingModel, pending) != p {
				t.Fatal("lease did not authorize reservation")
			}
			d := &dispatchState{s: s, provider: p, pr: pending, timing: timing}
			builder := providerInferenceFrameBuilder(pending.RequestID, "ephemeral", "ciphertext", pending)
			metadata, err := d.writeQueuedProviderInferenceRequest(context.Background(), func(at time.Time) ([]byte, error) {
				if reason == "expired" {
					<-time.After(time.Until(lease.ValidUntil))
				} else if reason == "build_revoked" {
					s.registry.SetAppAttestQualificationGeneration(1)
				} else {
					s.registry.RevokeAppAttestCredential(lease.CredentialID)
				}
				return builder(at)
			})
			if err == nil || metadata.Committed || d.providerDispatches != 0 || !timing.DispatchedAt.IsZero() || pending.Profile.WriteDequeuedUS.Load() != 0 {
				t.Fatalf("%s lease counted dispatch: metadata=%+v err=%v count=%d timing=%v", reason, metadata, err, d.providerDispatches, timing.DispatchedAt)
			}
			assertDispatchAccountingFrame(t, p, peer, false)
		})
	}
}
