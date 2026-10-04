package main_test

import (
	"reflect"
	"testing"
	"time"

	promptproof "github.com/eigeninference/d-inference/coordinator/internal/promptproof"
)

func TestColdStartSupervisorConfigOnlyExtendsPlanTimeout(t *testing.T) {
	args := promptproof.Config{
		BinaryPath:   "/tmp/promptsidecar",
		ArtifactRoot: "/tmp/prompt-artifacts",
		MaxRSSMiB:    1024,
	}
	const socketPath = "/tmp/promptsidecar.sock"
	const coldBurstPerContract = 16
	const coldStartPlanTimeout = 30 * time.Second
	production := promptproof.SupervisorConfig(args, socketPath, 3, coldBurstPerContract)
	cold := promptproof.ColdStartSupervisorConfig(args, socketPath, 3, coldBurstPerContract)

	if production.RequestTimeout != time.Second {
		t.Fatalf("production proof request timeout = %s, want 1s", production.RequestTimeout)
	}
	if cold.RequestTimeout != coldStartPlanTimeout {
		t.Fatalf("cold-start request timeout = %s, want %s", cold.RequestTimeout, coldStartPlanTimeout)
	}

	cold.RequestTimeout = production.RequestTimeout
	if !reflect.DeepEqual(cold, production) {
		t.Fatal("cold-start proof changed supervisor settings beyond RequestTimeout")
	}
}
