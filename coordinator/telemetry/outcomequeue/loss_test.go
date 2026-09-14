package outcomequeue

import (
	"context"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
)

func TestRequestOutcomeSinkLossIsExplicit(t *testing.T) {
	q := &Sink{ch: make(chan store.RequestOutcomeRecord, 1)}
	q.Submit(store.RequestOutcomeRecord{})
	q.Submit(store.RequestOutcomeRecord{})
	if q.dropped.Load() != 1 {
		t.Fatal("full queue did not count drop")
	}
	q.closed = true
	q.Submit(store.RequestOutcomeRecord{})
	if q.dropped.Load() != 2 {
		t.Fatal("closed queue did not count drop")
	}
	for _, panicWrite := range []bool{false, true} {
		sink := New(Hooks{Write: func(context.Context, []store.RequestOutcomeRecord) error {
			if panicWrite {
				panic("fake failing dependency")
			}
			return errors.New("fake failing dependency")
		}}, 2)
		sink.Submit(store.RequestOutcomeRecord{CoordRequestID: "a"})
		sink.Close()
		if sink.failed.Load() != 1 || sink.written.Load() != 0 {
			t.Fatalf("failed sink fabricated persistence: failed=%d written=%d", sink.failed.Load(), sink.written.Load())
		}
	}
}
