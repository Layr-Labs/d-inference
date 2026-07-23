package main

import (
	"context"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

type rssSampler struct {
	supervisor *promptcontract.Supervisor
	interval   time.Duration
	stop       chan struct{}
	done       chan struct{}
	once       sync.Once
	peak       uint64
}

func newRSSSampler(
	supervisor *promptcontract.Supervisor,
	interval time.Duration,
	baseline uint64,
) *rssSampler {
	return &rssSampler{
		supervisor: supervisor,
		interval:   interval,
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
		peak:       baseline,
	}
}

func (s *rssSampler) Start(ctx context.Context) {
	go func() {
		defer close(s.done)
		ticker := time.NewTicker(s.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-s.stop:
				return
			case <-ticker.C:
				if rss := s.supervisor.Status().RSSBytes; rss > s.peak {
					s.peak = rss
				}
			}
		}
	}()
}

func (s *rssSampler) Stop() uint64 {
	s.once.Do(func() { close(s.stop) })
	<-s.done
	if rss := s.supervisor.Status().RSSBytes; rss > s.peak {
		s.peak = rss
	}
	return s.peak
}
