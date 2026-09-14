package mdmscheduler

import (
	"testing"
)

func TestMDMSchedulerHardBoundsClampEnvironmentAndProgrammaticConfig(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MDM_SCHEDULER_WORKERS", "99")
	t.Setenv("EIGENINFERENCE_MDM_SCHEDULER_QUEUE_CAPACITY", "99999")
	fromEnv := ConfigFromEnv()
	if fromEnv.Workers != defaultWorkers ||
		fromEnv.QueueCapacity != defaultQueue {
		t.Fatalf("environment scheduler bounds = %+v", fromEnv)
	}
	clamped := normalizeConfig(Config{
		Workers: 99, QueueCapacity: 99999,
	})
	if clamped.Workers != defaultWorkers ||
		clamped.QueueCapacity != defaultQueue {
		t.Fatalf("programmatic scheduler bounds = %+v", clamped)
	}
	_, _, constructed := newSchedulerHarness(t, Config{
		Workers: 99, QueueCapacity: 99999,
	}, Dependencies{})
	if constructed.cfg.Workers != defaultWorkers ||
		constructed.cfg.QueueCapacity != defaultQueue {
		t.Fatalf("constructed scheduler bounds = %+v", constructed.cfg)
	}
	lower := normalizeConfig(Config{
		Workers: 3, QueueCapacity: 17,
	})
	if lower.Workers != 3 || lower.QueueCapacity != 17 {
		t.Fatalf("lower positive scheduler options were not preserved: %+v", lower)
	}
}
