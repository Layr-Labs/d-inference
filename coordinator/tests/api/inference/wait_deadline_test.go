package inference_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func waitDeadlineFixture(t *testing.T, receivedAgo, deadline time.Duration) (*serverFixture, *registry.Provider, *registry.PendingRequest, *http.Request) {
	t.Helper()
	s := newTestServerForDispatch(t)
	st, ok := s.store.(*memory.MemoryStore)
	if !ok {
		t.Fatalf("store = %T", s.store)
	}
	const model = "first-token-deadline-model"
	provider := s.registry.Register("first-token-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
	})
	receivedAt := time.Now().Add(-receivedAgo)
	pr := &registry.PendingRequest{
		RequestID: "first-token-request", Attempt: 0,
		FirstContentDeadline: receivedAt.Add(deadline), ProviderID: provider.ID, Model: model,
		ChunkCh: make(chan registry.ProviderChunk, 1), AcceptedCh: make(chan struct{}, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
		Timing: &registry.RequestTiming{ReceivedAt: receivedAt},
	}
	provider.AddPending(pr)
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID: pr.RequestID, Attempt: pr.Attempt, ProviderID: provider.ID, Model: model,
	}); err != nil {
		t.Fatalf("record route: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if err != nil {
		t.Fatal(err)
	}
	return s, provider, pr, req
}

func acceptedDeadlineWait(s *serverFixture, provider *registry.Provider, pr *registry.PendingRequest, req *http.Request, deadline time.Duration) func() (attempt.Outcome, attempt.TimeoutResult) {
	timeout := s.NewWaitTimeout(attempt.TimeoutConfig{
		Model: pr.Model, Provider: provider, Pending: pr, RequestID: pr.RequestID, Attempt: 0,
	})
	var terminal attempt.TimeoutResult
	waiter := attempt.NewAcceptedWait(attempt.AcceptedWaitDependencies{
		Timeout: func(budget time.Duration) bool {
			terminal = timeout.Run(req.Context(), attempt.AcceptedTimeout, budget)
			return terminal.Claimed
		},
	}, attempt.AcceptedWaitConfig{
		Pending: pr, Deadline: deadline,
		Clock: firstcontent.NewClock(pr.Timing.ReceivedAt, deadline, deadline/2),
	})
	var held []string
	return func() (attempt.Outcome, attempt.TimeoutResult) {
		got := waiter.Run(req.Context(), &held)
		return got, terminal
	}
}

func TestWaitAcceptedKeepsRequestAbsoluteDeadline(t *testing.T) {
	s, provider, pr, req := waitDeadlineFixture(t, 8*time.Second, 9*time.Second)
	wait := acceptedDeadlineWait(s, provider, pr, req, 9*time.Second)
	start := time.Now()
	got, terminal := wait()
	elapsed := time.Since(start)
	if got != attempt.Retry {
		t.Fatalf("waitAccepted=%v want outcomeRetry", got)
	}
	if terminal.Failure.Message.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d want 504", terminal.Failure.Message.StatusCode)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("accepted wait used leftover SLA, but took %s (would be 600s before the fix)", elapsed)
	}
}

func emptyCompletionWait(s *serverFixture, provider *registry.Provider, pr *registry.PendingRequest, req *http.Request, deadline time.Duration) func() attempt.FirstWaitResult {
	timeout := s.NewWaitTimeout(attempt.TimeoutConfig{
		Model: pr.Model, Provider: provider, Pending: pr, RequestID: pr.RequestID, Attempt: 0,
	})
	committer := s.NewContentCommitter()
	var held []string
	waiter := attempt.NewFirstWait(attempt.FirstWaitDependencies{
		Commit: func(chunk string) { committer.Commit(nil, pr, len(held), chunk) },
		CommitReady: func(msg protocol.InferenceErrorMessage) bool {
			return committer.Buffered(nil, pr, &held, msg) != nil
		},
		Timeout: func() bool {
			return timeout.Run(req.Context(), attempt.FirstContentTimeout, deadline).Claimed
		},
	}, attempt.FirstWaitConfig{
		Pending: pr, Timing: pr.Timing, Deadline: deadline, SpeculativeAt: deadline / 2,
	})
	return func() attempt.FirstWaitResult { return waiter.Run(req.Context(), &held) }
}

func TestWaitFirstChunkPreservesOnTimeEmptyCompletionDuringSettlement(t *testing.T) {
	s, provider, pr, req := waitDeadlineFixture(t, 2*time.Second, time.Second)
	wait := emptyCompletionWait(s, provider, pr, req, time.Second)
	pr.MarkCompletionIngress(pr.FirstContentDeadline.Add(-time.Millisecond))

	resultCh := make(chan attempt.Outcome, 1)
	var result attempt.FirstWaitResult
	go func() {
		result = wait()
		resultCh <- result.Outcome
	}()

	select {
	case got := <-resultCh:
		t.Fatalf("on-time completion timed out during settlement: %v", got)
	case <-time.After(50 * time.Millisecond):
	}
	pr.CompleteCh <- protocol.UsageInfo{}
	close(pr.ChunkCh)
	if got := <-resultCh; got != attempt.Committed {
		t.Fatalf("waitFirstChunk=%v, want committed on-time empty completion", got)
	}
	if result.Outcome != attempt.Committed {
		t.Fatal("on-time empty completion was not committed")
	}
}
