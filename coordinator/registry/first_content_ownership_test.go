package registry

import (
	"testing"
	"time"
)

func TestRemovePendingForFirstContentTimeoutDefersToOnTimeIngress(t *testing.T) {
	const requestID = "request"
	pr := &PendingRequest{
		RequestID:            requestID,
		FirstContentDeadline: time.Now().Add(time.Minute),
	}
	provider := &Provider{
		pendingReqs: map[string]*PendingRequest{requestID: pr},
	}

	got, receivedAt := provider.BeginPendingChunkIngress(requestID)
	if got != pr || receivedAt.IsZero() {
		t.Fatal("provider did not publish pending chunk ingress")
	}
	if removed, deferred := provider.RemovePendingForFirstContentTimeout(requestID); removed != nil || !deferred {
		t.Fatalf("timeout removal = (%p, %v), want (nil, true)", removed, deferred)
	}
	if provider.GetPending(requestID) != pr {
		t.Fatal("timeout removed request while on-time ingress classification was pending")
	}

	pr.FinishProviderChunkIngress(receivedAt, false)
	if removed, deferred := provider.RemovePendingForFirstContentTimeout(requestID); removed != pr || deferred {
		t.Fatalf("timeout removal after boilerplate = (%p, %v), want (%p, false)", removed, deferred, pr)
	}
}

func TestSpeculativeEmptyCompletionRequiresDispatchDecision(t *testing.T) {
	pr := &PendingRequest{}
	pr.EnableSpeculativeEmptyCompletionArbitration()

	select {
	case <-pr.emptyCompletionDecision:
		t.Fatal("empty completion settled before the dispatch owner decided")
	default:
	}

	pr.ResolveSpeculativeEmptyCompletion(false)
	accepted, waited := pr.AwaitSpeculativeEmptyCompletionDecision()
	if accepted || !waited {
		t.Fatalf("decision = (%v, %v), want (false, true)", accepted, waited)
	}
}
