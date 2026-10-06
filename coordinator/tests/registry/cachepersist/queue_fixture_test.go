package cachepersist_test

import (
	"context"
	"log/slog"
	"testing"
	"time"

	core "github.com/eigeninference/d-inference/coordinator/internal/registry/cachepersist"
	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"
	public "github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

type Persister struct {
	*core.Persister
	*cachequeue.Queue
}

func (p *Persister) Ready() bool { return p.Persister.Ready() }

type Options = public.Options

const (
	HolderFlushRows          = public.HolderFlushRows
	DemandPersistGranularity = public.DemandPersistGranularity
	pruneBatchRows           = cachequeue.PruneBatchRows
)

func New(st crs.Store, logger *slog.Logger, opts Options) *Persister {
	q := cachequeue.New(opts.MaxPending, opts.DemandTTL)
	return &Persister{Persister: core.New(st, logger, opts.Fingerprint, q), Queue: q}
}

func rememberDelete(t *testing.T, p *Persister, k crs.HolderKey, at time.Time) {
	t.Helper()
	// Exercise the real write/acknowledgement path for retained decisions.
	ready := p.Ready()
	p.MarkHolderDelete(k, at)
	if !ready {
		if _, err := p.Restore(context.Background(), at, time.Minute, 1000, 0); err != nil {
			t.Fatal(err)
		}
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	// A retention-only fixture still exercises the pre-restore prune path.
	if !ready {
		p.Mu.Lock()
		p.Queue.Ready = false
		p.Mu.Unlock()
	}
}
