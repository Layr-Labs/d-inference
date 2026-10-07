package service_test

import (
	"strings"
	"testing"

	service "github.com/eigeninference/d-inference/coordinator/appattest/service"

	cohort "github.com/eigeninference/d-inference/coordinator/internal/appattest/cohort"
)

func TestAppAttestRolloutRequiresOptInAndIdentity(t *testing.T) {
	for _, percent := range []int{-1, 0, 101} {
		if cohort.Enrollment("account", "machine", percent) == "enabled" {
			t.Fatal("invalid or disabled rollout enabled")
		}
	}
	if cohort.Enrollment("", "machine", 100) == "enabled" {
		t.Fatal("anonymous enrollment enabled")
	}
	if got := cohort.Enrollment("account", "", 100); got != "identity_required" {
		t.Fatalf("missing machine identity: %s", got)
	}
	for i := 0; i < 100; i++ {
		machine := strings.Repeat("m", i+1)
		if cohort.Enrollment("a", machine, 100) != "enabled" {
			t.Fatal("full rollout excluded a client")
		}
		if cohort.Enrollment("a", machine, 10) == "enabled" && cohort.Enrollment("a", machine, 20) != "enabled" {
			t.Fatal("cohort shrank when percentage increased")
		}
	}
	for percent := 1; percent <= 99; percent++ {
		if cohort.Enrollment("same-account", "first-provisional", percent) != cohort.Enrollment("same-account", "replacement-provisional", percent) {
			t.Fatal("reconnect rerolled account cohort")
		}
	}
	t.Setenv("EIGENINFERENCE_APP_ATTEST_SHADOW", "")
	t.Setenv("EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT", "")
	if c := service.ConfigFromEnvironment(); c.Enabled || c.RolloutPercent != 0 {
		t.Fatal("rollout must default off")
	}
}
