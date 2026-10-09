package firstcontent_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
)

func TestPromptWorkDeadlinePreservesEarlierContextCutoff(t *testing.T) {
	received := time.Now()
	ctx, cancel := context.WithDeadline(context.Background(), received.Add(3*time.Second))
	defer cancel()
	if got := firstcontent.DurationWithinContext(ctx, received, 14*time.Second); got != 3*time.Second {
		t.Fatal("caller cutoff was extended", got)
	}
	if got := firstcontent.DurationWithinContext(ctx, received, time.Second); got != time.Second {
		t.Fatal("earlier SLA was extended", got)
	}
	if got := firstcontent.DurationWithinContext(ctx, received, 0); got != 0 {
		t.Fatal("context cutoff enabled exempt SLA")
	}
	expired, cancelExpired := context.WithDeadline(context.Background(), received.Add(-time.Second))
	defer cancelExpired()
	if got := firstcontent.DurationWithinContext(expired, received, 14*time.Second); got != time.Nanosecond {
		t.Fatal("expired cutoff became exempt", got)
	}
}
