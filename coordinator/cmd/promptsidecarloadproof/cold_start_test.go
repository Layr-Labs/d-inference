package main

import (
	"reflect"
	"testing"
	"time"
)

func TestColdStartSupervisorConfigOnlyExtendsPlanTimeout(t *testing.T) {
	args := arguments{
		BinaryPath:   "/tmp/promptsidecar",
		ArtifactRoot: "/tmp/prompt-artifacts",
		MaxRSSMiB:    1024,
	}
	const socketPath = "/tmp/promptsidecar.sock"
	production := proofSupervisorConfig(args, socketPath, 3, coldBurstPerContract)
	cold := coldStartSupervisorConfig(args, socketPath, 3, coldBurstPerContract)

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
