package registry

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Autopilot requires BOTH an operator rollout flag and provider consent. Shadow
// mode never adds command reservations/fences or sends commands. Provider opt-in
// independently changes the provider contract to managed, warm-only serving.
type AutopilotConfig struct {
	Enabled                 bool
	ObserveOnly             bool
	Interval                time.Duration
	DemandWindow            time.Duration
	MinDwell                time.Duration
	IdleUnloadAfter         time.Duration
	MaxSnapshotAge          time.Duration
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

func DefaultAutopilotConfig() AutopilotConfig {
	return AutopilotConfig{
		ObserveOnly: true, Interval: 10 * time.Second, DemandWindow: 5 * time.Minute,
		MinDwell: 30 * time.Minute, IdleUnloadAfter: time.Hour,
		MaxSnapshotAge: 30 * time.Second, CommandAcceptTimeout: 20 * time.Second,
		CommandWatchdog: 5 * time.Minute, FailureBackoff: 2 * time.Minute,
		LoadTimePrior:     30 * time.Second,
		MaxActionsPerTick: 2, MaxConcurrentOperations: 4,
		TargetUtilization: .7, MinBenefitSeconds: 30,
	}
}

func autopilotConfigFromEnv() AutopilotConfig {
	c := DefaultAutopilotConfig()
	p := env.EnvPrefix + "_AUTOPILOT_"
	c.Enabled = env.EnvBool(p+"ENABLED", false)
	c.ObserveOnly = env.EnvBool(p+"OBSERVE_ONLY", true)
	c.Interval = envDuration(p+"INTERVAL", c.Interval)
	c.DemandWindow = envDuration(p+"DEMAND_WINDOW", c.DemandWindow)
	c.MinDwell = envDuration(p+"MIN_DWELL", c.MinDwell)
	c.IdleUnloadAfter = envDuration(p+"IDLE_UNLOAD_AFTER", c.IdleUnloadAfter)
	c.LoadTimePrior = envDuration(p+"LOAD_TIME_PRIOR", c.LoadTimePrior)
	c.MaxActionsPerTick = env.EnvInt(p+"MAX_ACTIONS_PER_TICK", c.MaxActionsPerTick)
	c.MaxConcurrentOperations = env.EnvInt(p+"MAX_CONCURRENT_OPERATIONS", c.MaxConcurrentOperations)
	c.TargetUtilization = env.EnvFloat(p+"TARGET_UTILIZATION", c.TargetUtilization)
	c.AllowIdleUnload = env.EnvBool(p+"ALLOW_IDLE_UNLOAD", false)
	return c
}

func (c AutopilotConfig) Check() error {
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
