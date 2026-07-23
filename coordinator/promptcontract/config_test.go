package promptcontract

import (
	"testing"
	"time"
)

func TestDefaultArtifactRootUsesPhysicalPersistentPath(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT", "")

	config := ReadSupervisorConfig()
	if config.ArtifactRoot != "/mnt/disks/userdata/prompt-contracts" {
		t.Fatalf("artifact root = %q", config.ArtifactRoot)
	}
}

func TestSupervisorSafetyDefaultsSeparatePlanningHealthAndPreload(t *testing.T) {
	config := ReadSupervisorConfig()
	if config.RequestTimeout != time.Second || config.HealthTimeout != 250*time.Millisecond ||
		config.PreloadTimeout != 2*time.Minute || config.StartupTimeout != 2*time.Minute {
		t.Fatalf("independent timeout defaults=%+v", config)
	}
	if config.HealthInterval != time.Second || config.HealthFailureThreshold != 5 {
		t.Fatalf("health defaults=%+v", config)
	}
	if config.RestartWindow != time.Minute || config.RestartMaxInWindow != 3 ||
		config.RestartCooldown != 30*time.Second || config.StderrMaxBytes != 16<<10 {
		t.Fatalf("restart/diagnostic defaults=%+v", config)
	}
}

func TestSupervisorConfigRejectsOneStrikeHealthRestart(t *testing.T) {
	config := ReadSupervisorConfig()
	config.Enabled = true
	config.HealthFailureThreshold = 1
	if err := config.Check(); err == nil {
		t.Fatal("one-strike health restart threshold was accepted")
	}
}
