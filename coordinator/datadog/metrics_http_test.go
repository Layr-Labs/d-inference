package datadog

import "testing"

func TestSeriesBufferLastWriteWins(t *testing.T) {
	b := newSeriesBuffer()
	b.setGauge("providers.online", 10, []string{"env:prod"}, 100)
	b.setGauge("providers.online", 12, []string{"env:prod"}, 101) // same series → overwrite
	b.setGauge("providers.online", 3, []string{"version:0.6.3"}, 101)

	pts := b.drain()
	if len(pts) != 2 {
		t.Fatalf("expected 2 distinct series, got %d", len(pts))
	}
	for _, p := range pts {
		if p.metric == "providers.online" && len(p.tags) == 1 && p.tags[0] == "env:prod" && p.value != 12 {
			t.Fatalf("last-write-wins failed: got %v want 12", p.value)
		}
	}

	// Drain empties the buffer.
	if again := b.drain(); again != nil {
		t.Fatalf("drain should empty the buffer, got %d points", len(again))
	}
}
