package registry

import (
	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func autopilotConfigFromEnv() autopilot.Config {
	c := autopilot.DefaultConfig()
	p := env.EnvPrefix + "_AUTOPILOT_"
	c.Enabled = env.EnvBool(p+"ENABLED", c.Enabled)
	c.ObserveOnly = env.EnvBool(p+"OBSERVE_ONLY", c.ObserveOnly)
	c.Interval = envDuration(p+"INTERVAL", c.Interval)
	c.DemandWindow = envDuration(p+"DEMAND_WINDOW", c.DemandWindow)
	c.MinDwell = envDuration(p+"MIN_DWELL", c.MinDwell)
	c.IdleUnloadAfter = envDuration(p+"IDLE_UNLOAD_AFTER", c.IdleUnloadAfter)
	c.LoadTimePrior = envDuration(p+"LOAD_TIME_PRIOR", c.LoadTimePrior)
	c.MaxActionsPerTick = env.EnvInt(p+"MAX_ACTIONS_PER_TICK", c.MaxActionsPerTick)
	c.MaxConcurrentOperations = env.EnvInt(p+"MAX_CONCURRENT_OPERATIONS", c.MaxConcurrentOperations)
	c.TargetUtilization = env.EnvFloat(p+"TARGET_UTILIZATION", c.TargetUtilization)
	c.AllowIdleUnload = env.EnvBool(p+"ALLOW_IDLE_UNLOAD", true)
	return c
}
