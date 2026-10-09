package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func deadlineHandoffFixture(t *testing.T, matching bool, preparations ...*reservationPreparationFixture) (*production.Registry, *production.Provider, *production.PendingRequest, *atomic.Int32) {
	t.Helper()
	frames := &atomic.Int32{}
	w := newWriterFixture(8, 8, nil, nil, func([]byte) error { frames.Add(1); return nil }, nil)
	t.Cleanup(w.Close)
	go w.Run()
	deps := production.Dependencies{Connections: retainedWriterFactory{writer: w.Writer}}
	if len(preparations) > 0 {
		deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
			preparations[0].planner = planner
			return preparations[0]
		}
	}
	r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), deps))
	artifact, contract := strings.Repeat("a", 64), strings.Repeat("b", 64)
	p.Mu().Lock()
	p.Models[0].WeightHash = artifact
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: appAttestTestModel, State: "idle", MaxConcurrency: 8, ActiveTokenBudgetMax: 100000}}}
	if matching {
		p.BackendCapacity.Slots[0].PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: artifact, PromptContractID: contract}
	}
	p.Mu().Unlock()
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	now := time.Now()
	pr := &production.PendingRequest{RequestID: "deadline-handoff", Model: appAttestTestModel, EstimatedPromptTokens: 500, RequestedMaxTokens: 32,
		PromptWork:                   &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 1200, UpperBoundTokens: 1200, ModelArtifactHash: artifact, PromptContractID: contract},
		FirstContentFallbackDeadline: now.Add(20 * time.Second), FirstContentQualifiedDeadline: now.Add(10 * time.Second)}
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	return r, p, pr, frames
}

func freshServingDeadlineRequest(pr *production.PendingRequest, id string) *production.PendingRequest {
	pending := &production.PendingRequest{RequestID: id, Model: pr.Model, EstimatedPromptTokens: pr.EstimatedPromptTokens,
		RequestedMaxTokens: pr.RequestedMaxTokens, PromptWork: pr.PromptWork,
		FirstContentFallbackDeadline: pr.FirstContentFallbackDeadline, FirstContentQualifiedDeadline: pr.FirstContentQualifiedDeadline,
	}
	pending.FirstContentDeadline = pending.FirstContentDeadlineEnvelope()
	return pending
}
