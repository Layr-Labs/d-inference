// Package queuedrain owns bounded drain suppression and per-model pass claims.
package queuedrain

import (
	"sync"
	"time"
)

const SuppressionWindow = 20 * time.Millisecond

// Scheduler retains the lifetime of a delayed drain. Implementations must run
// the supplied work once after the delay, without holding a suppression lock.
type Scheduler interface {
	Schedule(time.Duration, func())
}

type WallScheduler struct{}

func (WallScheduler) Schedule(delay time.Duration, run func()) { time.AfterFunc(delay, run) }

type Suppressor struct {
	mu        sync.Mutex
	saturated map[string]time.Time
	trailing  map[string]bool
	now       func() time.Time
	scheduler Scheduler
}

func NewSuppressor(now func() time.Time, scheduler Scheduler) *Suppressor {
	return &Suppressor{now: now, scheduler: scheduler}
}

func (s *Suppressor) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

func (s *Suppressor) MarkSaturated(model string) {
	now := s.clock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.saturated == nil {
		s.saturated = make(map[string]time.Time)
	}
	s.saturated[model] = now
}

func (s *Suppressor) Clear(model string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.saturated, model)
}

func (s *Suppressor) Suppressed(model string) bool { return s.suppressedAt(model, s.clock()) }

func (s *Suppressor) suppressedAt(model string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	last, ok := s.saturated[model]
	return ok && now.Sub(last) < SuppressionWindow
}

// Unsuppressed returns the original slice when no entry is suppressed.
func (s *Suppressor) Unsuppressed(models []string) []string {
	now := s.clock()
	var kept []string
	for i, model := range models {
		if !s.suppressedAt(model, now) {
			if kept != nil {
				kept = append(kept, model)
			}
			continue
		}
		if kept == nil {
			kept = append(make([]string, 0, len(models)-1), models[:i]...)
		}
	}
	if kept == nil {
		return models
	}
	return kept
}

// Arm coalesces suppressed heartbeats into one delayed, unsuppressed drain per
// model. It releases the arm before running work so a later heartbeat can arm
// the next window. The drain callback is the actual registry consumer.
func (s *Suppressor) Arm(models, kept []string, drain func(string)) {
	keptSet := make(map[string]struct{}, len(kept))
	for _, model := range kept {
		keptSet[model] = struct{}{}
	}
	s.mu.Lock()
	if s.trailing == nil {
		s.trailing = make(map[string]bool)
	}
	var arm []string
	for _, model := range models {
		if _, ok := keptSet[model]; ok || s.trailing[model] {
			continue
		}
		s.trailing[model] = true
		arm = append(arm, model)
	}
	s.mu.Unlock()
	scheduler := s.scheduler
	if scheduler == nil {
		scheduler = WallScheduler{}
	}
	for _, model := range arm {
		model := model
		scheduler.Schedule(SuppressionWindow, func() {
			s.mu.Lock()
			delete(s.trailing, model)
			s.mu.Unlock()
			drain(model)
		})
	}
}
