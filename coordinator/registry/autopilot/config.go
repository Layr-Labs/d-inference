package autopilot

import (
	"fmt"
	"time"
)

// Autopilot requires provider consent and a live coordinator control lease.
// Operators can disable it or select inert observation. Consent alone retains
// ordinary residency behavior until control is active (or explicitly paused).
type Config struct {
	Enabled                 bool
	ObserveOnly             bool
	Interval                time.Duration
	DemandWindow            time.Duration
	MinDwell                time.Duration
	IdleUnloadAfter         time.Duration
	MaxSnapshotAge          time.Duration // baseline active-control budget, resolved against renewal cadence
	CommandAcceptTimeout    time.Duration
	CommandWatchdog         time.Duration
	FailureBackoff          time.Duration
	LoadTimePrior           time.Duration
	MaxActionsPerTick       int
	MaxConcurrentOperations int
	TargetUtilization       float64
	MinBenefitSeconds       float64
	AllowIdleUnload         bool
}

func DefaultConfig() Config {
	return Config{
		Enabled: true, ObserveOnly: true, Interval: 10 * time.Second, DemandWindow: 5 * time.Minute,
		MinDwell: 30 * time.Minute, IdleUnloadAfter: time.Hour,
		MaxSnapshotAge: 30 * time.Second, CommandAcceptTimeout: 20 * time.Second,
		CommandWatchdog: 5 * time.Minute, FailureBackoff: 2 * time.Minute,
		LoadTimePrior:     30 * time.Second,
		MaxActionsPerTick: 2, MaxConcurrentOperations: 4,
		TargetUtilization: .7, MinBenefitSeconds: 30, AllowIdleUnload: true,
	}
}

// ControlSnapshotMaxAge allows a controller interval plus delivery jitter.
// The default remains 30s; a valid one-minute interval resolves to 70s.
func (c Config) ControlSnapshotMaxAge() time.Duration {
	return max(c.MaxSnapshotAge, c.Interval+10*time.Second)
}

func (c Config) Check() error {
	if !c.Enabled {
		return nil
	}
	if c.Interval < time.Second || c.Interval > time.Minute || c.DemandWindow < time.Minute || c.DemandWindow > 30*time.Minute {
		return fmt.Errorf("registry: autopilot interval must be 1s..1m and demand window 1m..30m")
	}
	if c.MinDwell < time.Minute || c.MinDwell > 24*time.Hour || c.IdleUnloadAfter < c.MinDwell || c.IdleUnloadAfter > 24*time.Hour {
		return fmt.Errorf("registry: autopilot dwell must be 1m..24h and idle unload after dwell, at most 24h")
	}
	if c.MaxActionsPerTick < 1 || c.MaxActionsPerTick > 32 || c.MaxConcurrentOperations < 1 || c.MaxConcurrentOperations > 64 {
		return fmt.Errorf("registry: autopilot operation limits are out of range")
	}
	if c.MaxSnapshotAge < time.Second || c.MaxSnapshotAge > time.Minute || c.CommandAcceptTimeout < time.Second || c.CommandAcceptTimeout > 5*time.Minute || c.CommandWatchdog < c.CommandAcceptTimeout || c.CommandWatchdog > 30*time.Minute || c.FailureBackoff < time.Second || c.FailureBackoff > time.Hour || c.LoadTimePrior < time.Second || c.LoadTimePrior > 5*time.Minute {
		return fmt.Errorf("registry: autopilot freshness, deadline, watchdog, backoff or load prior is out of range")
	}
	if !(c.TargetUtilization >= .1 && c.TargetUtilization <= .9) || !(c.MinBenefitSeconds >= 0 && c.MinBenefitSeconds <= 3600) {
		return fmt.Errorf("registry: autopilot utilization/benefit settings are out of range")
	}
	return nil
}
