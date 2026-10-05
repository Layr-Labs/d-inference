package verification

import "time"

func NormalizeConfig(cfg Config) Config {
	if cfg.Workers <= 0 {
		cfg.Workers = MaxWorkers
	} else if cfg.Workers > MaxWorkers {
		cfg.Workers = MaxWorkers
	}
	if cfg.QueueCapacity <= 0 {
		cfg.QueueCapacity = MaxQueueCapacity
	} else if cfg.QueueCapacity > MaxQueueCapacity {
		cfg.QueueCapacity = MaxQueueCapacity
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
