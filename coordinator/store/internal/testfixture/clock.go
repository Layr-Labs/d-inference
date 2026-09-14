package testfixture

import (
	"sync"
	"time"
)

type Clock struct {
	mu sync.Mutex
	t  time.Time
}

func NewClock() *Clock {
	return &Clock{t: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)}
}

func (f *Clock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

func (f *Clock) Advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}
