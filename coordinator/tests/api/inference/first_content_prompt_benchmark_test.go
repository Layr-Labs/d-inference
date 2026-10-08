package inference_test

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Measure the additional hot-path metadata reads for deadline reconciliation.
// Tokenization and setup are outside the timed loop; this is overhead evidence,
// not a claim about model throughput or time to first content.
func BenchmarkPromptWorkDeadline(b *testing.B) {
	logger := slog.New(slog.DiscardHandler)
	s := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{FirstContentDeadlineBase: 9 * time.Second}, logger)
	b.Cleanup(s.Close)
	f := newPromptDeadlineFixture(b, s)
	work := deadlineFixtureWork(b, s.Owner, f.model, 5779)
	received := time.Now()
	fallback := s.FirstContentDeadline(f.model, 3606)
	for _, name := range []string{"heuristic", "qualified_exact", "earlier_context"} {
		b.Run(name, func(b *testing.B) {
			ctx := context.Background()
			if name == "earlier_context" {
				var cancel context.CancelFunc
				ctx, cancel = context.WithDeadline(ctx, received.Add(3*time.Second))
				defer cancel()
			}
			deadline := s.PromptWorkDeadlineForRequest(ctx, received, f.model, fallback)
			input := work
			if name == "heuristic" {
				input = nil
			}
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				if deadline(f.model, input) <= 0 {
					b.Fatal("deadline disabled")
				}
			}
		})
	}
}
