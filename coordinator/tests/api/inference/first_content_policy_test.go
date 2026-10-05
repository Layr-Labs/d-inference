package inference_test

import (
	"context"
	"testing"
	"time"

	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstTokenRemainingSince(t *testing.T) {
	t.Parallel()
	if got := firstcontent.FirstTokenRemainingSince(time.Time{}, 9*time.Second); got != 9*time.Second {
		t.Fatalf("zero receivedAt: got %s want 9s", got)
	}
	if got := firstcontent.FirstTokenRemainingSince(time.Now(), 0); got != 0 {
		t.Fatalf("zero deadline: got %s", got)
	}
	got := firstcontent.FirstTokenRemainingSince(time.Now().Add(-8*time.Second), 9*time.Second)
	if got < 500*time.Millisecond || got > 1500*time.Millisecond {
		t.Fatalf("8s-old receive against 9s deadline: remaining=%s", got)
	}
	if got := firstcontent.FirstTokenRemainingSince(time.Now().Add(-15*time.Second), 9*time.Second); got != 0 {
		t.Fatalf("expired clock: got %s want 0", got)
	}
}

func TestFirstContentBudgetMillis(t *testing.T) {
	t.Parallel()

	if got, ok := firstcontent.FirstContentBudgetMillis(time.Time{}, 9*time.Second); !ok || got != 0 {
		t.Fatalf("unstamped clock = (%d,%v), want omitted+dispatchable", got, ok)
	}

	got, ok := firstcontent.FirstContentBudgetMillis(
		time.Now().Add(-8*time.Second), 9*time.Second)
	if !ok || got < 500 || got > 1500 {
		t.Fatalf("remaining budget = (%d,%v), want about 1000ms", got, ok)
	}

	if got, ok := firstcontent.FirstContentBudgetMillis(
		time.Now().Add(-15*time.Second), 9*time.Second); ok || got != 0 {
		t.Fatalf("expired clock = (%d,%v), want zero+blocked", got, ok)
	}
}

func TestProviderAttributableStall(t *testing.T) {
	t.Parallel()
	if firstcontent.ProviderAttemptAttributableStall(nil, firstcontent.PreambleContentTimeout-time.Second) {
		t.Fatal("a wait capped below the preamble-content window is OUR clock, not provider fault")
	}
	if !firstcontent.ProviderAttemptAttributableStall(nil, firstcontent.PreambleContentTimeout) {
		t.Fatal("a full preamble-content window of silence is provider-attributable")
	}
	if !firstcontent.ProviderAttemptAttributableStall(nil, 600*time.Second) {
		t.Fatal("the historical uncapped accepted budget must stay provider-attributable")
	}
	pr := &registry.PendingRequest{
		Timing: &registry.RequestTiming{
			DispatchedAt: time.Now().Add(-firstcontent.PreambleContentTimeout - time.Second),
		},
	}
	if !firstcontent.ProviderAttemptAttributableStall(pr, time.Second) {
		t.Fatal("full initial provider interval must count even when extension is short")
	}
}

func TestFirstTokenWriteContext(t *testing.T) {
	t.Parallel()
	base := context.Background()

	ctx, cancel := firstcontent.FirstTokenWriteContext(base, time.Time{}, 9*time.Second)
	if _, ok := ctx.Deadline(); ok {
		t.Fatal("zero receivedAt must pass the context through unbounded")
	}
	cancel()

	receivedAt := time.Now().Add(-8 * time.Second)
	ctx, cancel = firstcontent.FirstTokenWriteContext(base, receivedAt, 9*time.Second)
	defer cancel()
	dl, ok := ctx.Deadline()
	if !ok {
		t.Fatal("request clock set: write context must carry the first-token deadline")
	}
	if want := receivedAt.Add(9 * time.Second); !dl.Equal(want) {
		t.Fatalf("deadline=%s want %s", dl, want)
	}

	expired, cancelExpired := firstcontent.FirstTokenWriteContext(base, time.Now().Add(-15*time.Second), 9*time.Second)
	defer cancelExpired()
	select {
	case <-expired.Done():
	case <-time.After(time.Second):
		t.Fatal("an already-expired clock must yield an already-done write context")
	}
}

func TestDrainReadyFirstContentPrefersBufferedToken(t *testing.T) {
	t.Parallel()
	deadline := time.Now().Add(time.Second)
	pr := &registry.PendingRequest{
		FirstContentDeadline: deadline,
		ChunkCh:              make(chan registry.ProviderChunk, 2),
	}
	var held []string
	if _, ok := firstcontent.DrainReadyFirstContent(pr, &held); ok {
		t.Fatal("empty channel must not produce content")
	}
	pr.ChunkCh <- registry.ProviderChunk{
		Data:       "hello-token",
		ReceivedAt: deadline.Add(-time.Millisecond),
	}
	chunk, ok := firstcontent.DrainReadyFirstContent(pr, &held)
	if !ok || chunk.Data != "hello-token" {
		t.Fatalf("drain=%q ok=%v want buffered token", chunk, ok)
	}
	closed := &registry.PendingRequest{ChunkCh: make(chan registry.ProviderChunk)}
	close(closed.ChunkCh)
	if _, ok := firstcontent.DrainReadyFirstContent(closed, &held); ok {
		t.Fatal("closed channel must fall through to the timeout path")
	}
}

func TestDrainReadyFirstContentDropsExcessBoilerplate(t *testing.T) {
	const maxHeldBoilerplate = 8
	pr := &registry.PendingRequest{ChunkCh: make(chan registry.ProviderChunk, maxHeldBoilerplate+2)}
	for i := 0; i < maxHeldBoilerplate+1; i++ {
		pr.ChunkCh <- registry.ProviderChunk{Data: roleOnlyChunkSSE("m")}
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: contentChunkSSE("m", "real-content")}
	var held []string
	chunk, ok := firstcontent.DrainReadyFirstContent(pr, &held)
	if !ok || chunk.Data != contentChunkSSE("m", "real-content") {
		t.Fatalf("drain returned ok=%v chunk=%q, want real content", ok, chunk)
	}
	if len(held) != maxHeldBoilerplate {
		t.Fatalf("held boilerplate=%d, want bounded %d", len(held), maxHeldBoilerplate)
	}
}

func TestEmptyCompletionOnlyPrecedesLaterSpeculativeContent(t *testing.T) {
	deadline := time.Now().Add(time.Second)
	empty := &registry.PendingRequest{FirstContentDeadline: deadline}
	completedAt := deadline.Add(-500 * time.Millisecond)
	empty.MarkCompletionIngress(completedAt)

	if !firstcontent.EmptyCompletionPrecedesChunk(empty, registry.ProviderChunk{
		Data:       "later",
		ReceivedAt: completedAt.Add(time.Millisecond),
	}) {
		t.Fatal("earlier empty completion did not win speculative ingress ordering")
	}
	if firstcontent.EmptyCompletionPrecedesChunk(empty, registry.ProviderChunk{
		Data:       "earlier",
		ReceivedAt: completedAt.Add(-time.Millisecond),
	}) {
		t.Fatal("later empty completion displaced earlier speculative content")
	}
}
