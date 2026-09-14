package profilequeue

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

const (
	batchMax  = 64
	batchWait = 250 * time.Millisecond
)

// worker drains the channel into batches and writes each batch with one store
// call inside a panic-safe wrapper. It never spawns per-record goroutines.
func (p *Sink) worker() {
	batch := make([]*store.RequestProfileRecord, 0, batchMax)
	for {
		select {
		case <-p.done:
			return
		case first := <-p.ch:
			batch = batch[:0]
			if rec := p.build(first); rec != nil {
				batch = append(batch, rec)
			}
			timer := time.NewTimer(batchWait)
		collect:
			for len(batch) < batchMax {
				select {
				case job := <-p.ch:
					if rec := p.build(job); rec != nil {
						batch = append(batch, rec)
					}
				case <-timer.C:
					break collect
				case <-p.done:
					timer.Stop()
					p.flush(batch)
					return
				}
			}
			timer.Stop()
			p.flush(batch)
		}
	}
}
