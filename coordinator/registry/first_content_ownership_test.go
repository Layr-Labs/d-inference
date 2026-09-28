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

func TestEmptyCompletionIngressUsesDeadlineAndEventOrder(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name                          string
		deadline, completion, content time.Time
		want                          bool
	}{
		{"unstamped without completion", time.Time{}, time.Time{}, time.Time{}, false},
		{"unbounded empty", time.Time{}, now, time.Time{}, true},
		{"unbounded prior content", time.Time{}, now, now.Add(-time.Millisecond), false},
		{"bounded empty", now.Add(time.Second), now, time.Time{}, true},
		{"expired empty", now.Add(-time.Second), now, time.Time{}, false},
		{"later content cannot strand completion", now.Add(time.Second), now, now.Add(time.Millisecond), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr := &PendingRequest{FirstContentDeadline: tc.deadline, completionIngressAt: tc.completion, firstContentIngressAt: tc.content}
			if _, got := pr.OnTimeEmptyCompletionIngress(); got != tc.want {
				t.Fatalf("eligible=%v want %v", got, tc.want)
			}
		})
	}
}
