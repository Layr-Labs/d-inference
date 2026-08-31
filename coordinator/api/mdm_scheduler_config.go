package api

import "time"

func normalizeMDMSchedulerConfig(cfg MDMSchedulerConfig) MDMSchedulerConfig {
	if cfg.Workers <= 0 {
		cfg.Workers = defaultMDMVerificationWorkers
	} else if cfg.Workers > defaultMDMVerificationWorkers {
		cfg.Workers = defaultMDMVerificationWorkers
	}
	if cfg.QueueCapacity <= 0 {
		cfg.QueueCapacity = defaultMDMVerificationQueue
	} else if cfg.QueueCapacity > defaultMDMVerificationQueue {
		cfg.QueueCapacity = defaultMDMVerificationQueue
	}
	if cfg.InitialSpreadMin < 0 {
		cfg.InitialSpreadMin = 0
	}
	if cfg.InitialSpreadMax < cfg.InitialSpreadMin {
		cfg.InitialSpreadMax = cfg.InitialSpreadMin
	}
	if cfg.InitialSpreadMax == 0 {
		cfg.InitialSpreadMin = 5 * time.Second
		cfg.InitialSpreadMax = 5 * time.Minute
	}
	if cfg.ClaimTTL <= 0 {
		cfg.ClaimTTL = 3 * time.Minute
	}
	return cfg
}
