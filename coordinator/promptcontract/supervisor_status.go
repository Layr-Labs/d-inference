package promptcontract

import (
	"log/slog"
	"time"
)

func (s *Supervisor) noteChildStarted(rssBytes uint64) uint64 {
	s.mu.Lock()
	s.status.ChildGeneration++
	generation := s.status.ChildGeneration
	s.status.Running = true
	s.status.Ready = false
	s.status.RSSBytes = rssBytes
	s.status.ConsecutiveHealthFailures = 0
	s.mu.Unlock()
	return generation
}

func (s *Supervisor) setRuntimeState(
	generation uint64,
	running, ready bool,
	rssBytes uint64,
	consecutiveFailures int,
) {
	s.mu.Lock()
	if s.status.ChildGeneration == generation {
		s.status.Running = running
		s.status.Ready = ready
		s.status.RSSBytes = rssBytes
		s.status.ConsecutiveHealthFailures = consecutiveFailures
	}
	s.mu.Unlock()
}

func (s *Supervisor) setChildStopped(generation uint64) {
	s.mu.Lock()
	if s.status.ChildGeneration == generation {
		s.status.Running = false
		s.status.Ready = false
		s.status.RSSBytes = 0
		s.status.ConsecutiveHealthFailures = 0
	}
	s.mu.Unlock()
}

func (s *Supervisor) setStopped() {
	s.mu.Lock()
	s.status.Running = false
	s.status.Ready = false
	s.status.RSSBytes = 0
	s.status.ConsecutiveHealthFailures = 0
	s.status.RestartSuppressedUntil = time.Time{}
	s.mu.Unlock()
}

func (s *Supervisor) noteRestart(reason, detail, stderr string) {
	reason = boundedSupervisorText(reason, maxSupervisorReasonBytes)
	detail = boundedSupervisorText(detail, maxSupervisorReasonBytes)
	stderr = boundedSupervisorText(stderr, s.config.StderrMaxBytes)
	s.mu.Lock()
	s.status.Restarts++
	s.lastRestartReason = reason
	s.status.RestartReason = s.lastRestartReason
	s.status.LastExitReason = detail
	s.status.StderrTail = stderr
	s.mu.Unlock()
	slog.Warn("prompt sidecar child restarting",
		"reason", reason,
		"exit_reason", detail,
		"stderr_tail", stderr,
	)
}

func (s *Supervisor) setRestartSuppressed(until time.Time) {
	s.mu.Lock()
	s.status.RestartSuppressedUntil = until
	if !until.IsZero() {
		s.status.RestartReason = "restart_cooldown"
	} else if s.status.RestartReason == "restart_cooldown" {
		s.status.RestartReason = s.lastRestartReason
	}
	s.mu.Unlock()
}

func (s *Supervisor) restartCircuitDelay(now time.Time, restartTimes *[]time.Time) time.Duration {
	cutoff := now.Add(-s.config.RestartWindow)
	times := *restartTimes
	kept := times[:0]
	for _, occurred := range times {
		if occurred.After(cutoff) {
			kept = append(kept, occurred)
		}
	}
	*restartTimes = kept
	if len(kept) < s.config.RestartMaxInWindow {
		return 0
	}
	windowRemaining := kept[0].Add(s.config.RestartWindow).Sub(now)
	if windowRemaining < s.config.RestartCooldown {
		return s.config.RestartCooldown
	}
	return windowRemaining
}
