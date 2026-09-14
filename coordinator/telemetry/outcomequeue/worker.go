package outcomequeue

import (
	"context"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func (q *Sink) run() {
	defer close(q.done)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	batch := make([]store.RequestOutcomeRecord, 0, 128)
	flush := func() {
		if len(batch) == 0 {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := func() (err error) {
			defer func() {
				if recover() != nil {
					err = errors.New("request outcome store panic")
				}
			}()
			return q.hooks.Write(ctx, batch)
		}()
		cancel()
		if err != nil {
			q.failed.Add(int64(len(batch)))
			if q.hooks.Count != nil {
				q.hooks.Count("request_outcomes.records", int64(len(batch)), []string{"status:write_failed"})
			}
			if q.hooks.Logger != nil {
				q.hooks.Logger.Warn("request outcomes persistence failed", "records", len(batch))
			}
		} else {
			q.written.Add(int64(len(batch)))
			if q.hooks.Count != nil {
				q.hooks.Count("request_outcomes.records", int64(len(batch)), []string{"status:written"})
			}
		}
		clear(batch)
		batch = batch[:0]
	}
	for {
		select {
		case r := <-q.ch:
			batch = append(batch, r)
			if len(batch) == cap(batch) {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-q.stop:
			for {
				select {
				case r := <-q.ch:
					batch = append(batch, r)
					if len(batch) == cap(batch) {
						flush()
					}
				default:
					flush()
					return
				}
			}
		}
	}
}
