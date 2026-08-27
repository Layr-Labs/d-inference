package api

import (
	"strings"
	"testing"
)

func TestServerConfigRejectsMalformedHardwareThreshold(t *testing.T) {
	t.Setenv("EIGENINFERENCE_HARDWARE_ADMISSION_MIN_MEMORY_GB", "thirty-two")
	cfg := ReadServerConfig()
	if err := cfg.Check(); err == nil ||
		!strings.Contains(err.Error(), "must be an integer") {
		t.Fatalf("malformed threshold error = %v", err)
	}
}

func TestServerConfigRejectsZeroThresholdEnforcement(t *testing.T) {
	cfg := ServerConfig{HardwareAdmissionMode: "enforce"}
	if err := cfg.Check(); err == nil ||
		!strings.Contains(err.Error(), "positive hardware threshold") {
		t.Fatalf("zero-threshold enforce error = %v", err)
	}
}
