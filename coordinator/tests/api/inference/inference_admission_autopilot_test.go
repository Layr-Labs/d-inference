package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

// Use the real registration boundary: a cached candidate appears in Models but
// never acquires ordinary serving permission from its shadow consent.
func registerAdmissionShadowProvider(srv *serverFixture) {
	selected := protocol.ModelInfo{ID: "terminal-healthy", ModelType: "chat", WeightHash: "selected"}
	cached := protocol.ModelInfo{ID: "terminal-unavailable", ModelType: "chat", WeightHash: "cached"}
	control := srv.registry.GetProvider("terminal-control-provider")
	control.Mu().Lock()
	metrics := control.SystemMetrics
	registration := &protocol.RegisterMessage{
		Hardware: control.Hardware, Backend: control.Backend, Version: control.Version,
		PublicKey: control.PublicKey, EncryptedResponseChunks: true, PrivacyCapabilities: control.PrivacyCapabilities,
		Models: []protocol.ModelInfo{selected}, AutopilotInventory: []protocol.ModelInfo{cached},
		ModelAutopilot: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, ObserveOnly: true,
			SelectedModels: []string{selected.ID, cached.ID}, Revision: "shadow-revision",
		},
	}
	control.Mu().Unlock()
	p := srv.registry.Register("shadow-provider", nil, registration)
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.AccountID = testConsumerID
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: "shadow-serial"}
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified, p.RuntimeManifestChecked, p.ChallengeVerifiedSIP = true, true, true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = metrics
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{
		{Model: selected.ID, State: "running"}, {Model: cached.ID, State: "running"},
	}}
}

func TestPreflightAutopilotShadowTerminalOwnership(t *testing.T) {
	for _, mode := range []string{"public_writer", "public_refund", "departed_refund", "self_writer", "serial_writer"} {
		t.Run(mode, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			if err := srv.registry.ConfigureAutopilot(autopilot.DefaultConfig()); err != nil {
				t.Fatal(err)
			}
			registerAdmissionShadowProvider(srv)
			barrier := newTerminalEffectBarrier()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			r, demand := srv.BeginAutopilotDemand(httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx), time.Now())
			if demand == nil {
				t.Fatal("shadow demand tracking was not enabled")
			}
			rec := httptest.NewRecorder()
			var writer http.ResponseWriter = &terminalEffectWriter{ResponseRecorder: rec, barrier: barrier}
			var refunds atomic.Int32
			params := inference.AdmissionRequest{
				Model: "terminal-unavailable", PublicModel: "terminal-unavailable", EstimatedPromptTokens: 27, RequestedMaxTokens: 64,
				Deadline: time.Second, ReceivedAt: time.Now(), RefundReservation: func() { refunds.Add(1) },
			}
			if mode == "public_refund" || mode == "departed_refund" {
				writer = rec
				params.RefundReservation = func() { refunds.Add(1); barrier.block() }
			}
			if mode == "self_writer" {
				params.Policy = access.SelfRoutePolicy{Enabled: true, OwnerAccountID: testConsumerID}
			}
			if mode == "serial_writer" {
				params.AllowedProviderSerials = []string{"shadow-serial"}
			}
			srv.scanGate.Acquire(0, nil)
			finished := make(chan struct{})
			var handled bool
			go func() {
				defer close(finished)
				handled = runAdmission(srv.NewAdmission(), writer, r, map[string]any{"model": params.Model}, params).Handled
			}()
			defer func() {
				cancel()
				barrier.release()
				select {
				case <-finished:
				case <-time.After(3 * time.Second):
					t.Error("admission did not retire after releasing terminal dependency")
				}
			}()
			select {
			case <-barrier.entered:
			case <-finished:
				t.Fatalf("shadow candidate was admitted or missed terminal dependency: status=%d body=%s", rec.Code, rec.Body.String())
			case <-time.After(3 * time.Second):
				t.Fatal("terminal dependency was not reached")
			}
			if got := srv.scanGate.InFlight(); got != 1 {
				t.Errorf("shadow rejection retains a scan permit: %d occupied, want only foreign permit", got)
			}
			terminalHealthyAdmission(t, srv)
			if mode == "departed_refund" {
				cancel()
			}
			barrier.release()
			select {
			case <-finished:
			case <-time.After(3 * time.Second):
				t.Fatal("terminal admission did not complete")
			}
			wantStatus := http.StatusTooManyRequests
			if mode == "self_writer" {
				wantStatus = http.StatusServiceUnavailable
			}
			if !handled || rec.Code != wantStatus || refunds.Load() != 1 || srv.scanGate.InFlight() != 1 {
				t.Fatalf("handled=%v status=%d refunds=%d permits=%d", handled, rec.Code, refunds.Load(), srv.scanGate.InFlight())
			}
			// Finish consumes exactly once: recording public demand here also
			// proves admission left it for the handler exit.
			sample, recorded := demand.Finish(rec.Code, r.Context().Err() != nil)
			wantRecorded := mode != "self_writer" && mode != "serial_writer"
			if recorded != wantRecorded {
				t.Fatalf("public demand recorded=%v want=%v sample=%+v", recorded, wantRecorded, sample)
			}
			if recorded {
				wantReason, wantShed := "no_eligible_provider", true
				if mode == "departed_refund" {
					wantReason, wantShed = "client_departure", false
				}
				if sample.Model != params.Model || sample.Reason != wantReason || sample.CapacityShed != wantShed || sample.Completed || sample.PromptTokens != 27 {
					t.Errorf("incorrect shadow terminal demand: %+v", sample)
				}
			}
			if _, again := demand.Finish(rec.Code, false); again {
				t.Error("terminal demand counted twice")
			}
			// The same shadow provider still serves its ordinary selected model
			// through owner routing; cached inventory must not poison selection.
			params.Model, params.PublicModel = "terminal-healthy", "terminal-healthy"
			params.Policy = access.SelfRoutePolicy{Enabled: true, OwnerAccountID: testConsumerID}
			params.AllowedProviderSerials = nil
			params.RefundReservation = func() { t.Error("selected model was refunded") }
			if rejected := runAdmission(srv.NewAdmission(), httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), map[string]any{"model": params.Model}, params).Handled; rejected {
				t.Error("ordinary selected model lost owner admission")
			}
			if srv.scanGate.InFlight() != 1 {
				t.Error("selected admission changed foreign permit ownership")
			}
			srv.scanGate.Release()
		})
	}
}

func TestPreflightAutopilotFallbackDemandAndPermit(t *testing.T) {
	for _, mode := range []string{"capacity_admitted", "capacity_body_error", "capacity_cancelled", "capacity_saturated", "ttft_admitted", "ttft_body_error"} {
		t.Run(mode, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			const desired, previous, public = "terminal-unavailable", "terminal-healthy", "terminal-alias"
			srv.registry.SetModelAliases(map[string]registry.AliasTarget{public: {Desired: desired, Previous: previous}})
			provider := registerBuildsProvider(srv, "fallback-desired", desired)
			if mode == "ttft_admitted" || mode == "ttft_body_error" {
				srv.SetTTFTHardReject(true)
				reportMeasuredFirstContentEvidence(t, srv.registry, provider.ID, desired, 10, 100)
				reportMeasuredFirstContentEvidence(t, srv.registry, "terminal-control-provider", previous, 1000, 1000)
			} else {
				provider.Mu().Lock()
				provider.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 4096
				provider.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 4096
				provider.Mu().Unlock()
			}
			r, demand, params := autopilotRequestFixture(t, srv)
			ctx, cancel := context.WithCancel(r.Context())
			defer cancel()
			r = r.WithContext(ctx)
			rec := httptest.NewRecorder()
			params.Model, params.PublicModel = desired, public
			params.EstimatedPromptTokens = 100
			params.Deadline, params.ReceivedAt = 5*time.Second, time.Now()
			params.TraitsForModel = func(model string) registry.RequestTraits {
				if model == previous {
					return registry.RequestTraits{HasTools: true, ToolChoiceMode: "auto", ToolChoiceName: "private-name", AvoidVersion: "private-retry"}
				}
				return registry.RequestTraits{}
			}
			var refunds, callbacks int
			params.RefundReservation = func() { refunds++ }
			srv.scanGate.Acquire(0, nil)
			params.OnModelFallback = func(model string) bool {
				callbacks++
				if model != previous || srv.scanGate.InFlight() != 1 {
					t.Errorf("fallback model=%s permits=%d, want previous/foreign-only", model, srv.scanGate.InFlight())
				}
				switch mode {
				case "capacity_body_error", "ttft_body_error":
					params.RefundReservation()
					rec.WriteHeader(http.StatusBadRequest)
					return false
				case "capacity_cancelled":
					cancel()
				case "capacity_saturated":
					srv.scanGate.Acquire(0, nil)
				}
				return true
			}
			result := runAdmission(srv.NewAdmission(), rec, r, map[string]any{"model": desired}, params)
			model, handled := result.Model, result.Handled
			wantHandled := mode != "capacity_admitted" && mode != "ttft_admitted"
			wantRefunds := 0
			if wantHandled {
				wantRefunds = 1
			}
			if model != previous || handled != wantHandled || callbacks != 1 || refunds != wantRefunds {
				t.Fatalf("fallback model=%s handled=%v callbacks=%d refunds=%d", model, handled, callbacks, refunds)
			}
			wantPermits := 1
			if mode == "capacity_saturated" {
				wantPermits = 2
			}
			if srv.scanGate.InFlight() != wantPermits {
				t.Fatalf("fallback consumed foreign permit or leaked own: %d", srv.scanGate.InFlight())
			}
			sample, recorded := demand.Finish(rec.Code, ctx.Err() != nil)
			wantRecorded := mode != "capacity_body_error" && mode != "ttft_body_error"
			if recorded != wantRecorded {
				t.Fatalf("fallback demand recorded=%v want=%v sample=%+v", recorded, wantRecorded, sample)
			}
			if recorded {
				wantReason := "admitted"
				if mode == "capacity_cancelled" {
					wantReason = "client_departure"
				} else if mode == "capacity_saturated" {
					wantReason = "routing_saturated"
				}
				if sample.Model != previous || sample.Requirements != params.TraitsForModel(previous).AutopilotRequirements(false) || sample.Reason != wantReason || sample.CapacityShed || sample.Completed {
					t.Errorf("final build/traits/terminal demand lost: %+v", sample)
				}
			}
			if _, again := demand.Finish(rec.Code, false); again {
				t.Error("fallback demand counted twice")
			}
			if mode == "capacity_cancelled" && rec.Body.Len() != 0 {
				t.Error("cancelled reacquisition wrote a response")
			}
			if mode == "capacity_saturated" && rec.Code != http.StatusTooManyRequests {
				t.Errorf("saturated reacquisition status=%d", rec.Code)
			}
			for range wantPermits {
				srv.scanGate.Release()
			}
		})
	}
}

func TestPreflightAutopilotAcquisitionTerminal(t *testing.T) {
	for _, departed := range []bool{false, true} {
		name := "saturated"
		if departed {
			name = "cancelled"
		}
		t.Run(name, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			r, demand, params := autopilotRequestFixture(t, srv)
			ctx, cancel := context.WithCancel(r.Context())
			defer cancel()
			r = r.WithContext(ctx)
			if departed {
				cancel()
			}
			params.Deadline, params.ReceivedAt = time.Millisecond, time.Now()
			var refunds int
			params.RefundReservation = func() { refunds++ }
			for range srv.scanGate.Capacity() {
				srv.scanGate.Acquire(0, nil)
			}
			rec := httptest.NewRecorder()
			handled := runAdmission(srv.NewAdmission(), rec, r, map[string]any{"model": params.Model}, params).Handled
			if !handled || refunds != 1 || srv.scanGate.InFlight() != srv.scanGate.Capacity() {
				t.Fatalf("acquisition handled=%v refunds=%d permits=%d", handled, refunds, srv.scanGate.InFlight())
			}
			sample, recorded := demand.Finish(rec.Code, departed)
			wantReason := "routing_saturated"
			if departed {
				wantReason = "client_departure"
			}
			if !recorded || sample.Model != params.Model || sample.Reason != wantReason || sample.CapacityShed || sample.Completed {
				t.Errorf("acquisition demand=%+v recorded=%v", sample, recorded)
			}
			if departed && rec.Body.Len() != 0 {
				t.Error("client departure emitted rejection")
			}
			for range srv.scanGate.Capacity() {
				srv.scanGate.Release()
			}
		})
	}
}

func TestPreflightAutopilotScopedSuccessDemand(t *testing.T) {
	for _, mode := range []string{"public", "self", "prefer", "serial"} {
		t.Run(mode, func(t *testing.T) {
			srv, _, _ := terminalEffectServer(t)
			registerAdmissionShadowProvider(srv)
			r, demand, params := autopilotRequestFixture(t, srv)
			params.Model, params.PublicModel = "terminal-healthy", "terminal-healthy"
			params.RefundReservation = func() { t.Error("successful admission refunded") }
			switch mode {
			case "self":
				params.Policy = access.SelfRoutePolicy{Enabled: true, OwnerAccountID: testConsumerID}
			case "prefer":
				params.Policy = access.SelfRoutePolicy{Prefer: true, OwnerAccountID: testConsumerID}
			case "serial":
				params.AllowedProviderSerials = []string{"shadow-serial"}
			}
			srv.scanGate.Acquire(0, nil)
			if handled := runAdmission(srv.NewAdmission(), httptest.NewRecorder(), r, map[string]any{"model": params.Model}, params).Handled; handled {
				t.Fatal("ordinary selected model was rejected")
			}
			sample, recorded := demand.Finish(http.StatusOK, false)
			if recorded != (mode == "public") || (recorded && (sample.Reason != "admitted" || sample.Model != params.Model || sample.Completed)) {
				t.Errorf("scope=%s demand=%+v recorded=%v", mode, sample, recorded)
			}
			if srv.scanGate.InFlight() != 1 {
				t.Error("scoped success changed foreign permit ownership")
			}
			srv.scanGate.Release()
		})
	}
}
