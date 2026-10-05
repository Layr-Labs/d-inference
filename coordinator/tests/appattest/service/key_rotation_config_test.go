package service_test

import (
	"testing"

	service "github.com/eigeninference/d-inference/coordinator/appattest/service"

	cohort "github.com/eigeninference/d-inference/coordinator/internal/appattest/cohort"
)

func TestKeyRotationPercentConfiguration(t *testing.T) {
	for raw, want := range map[string]int{"": 100, "0": 0, "37": 37, "abc": -1, "150": 150} {
		t.Setenv("EIGENINFERENCE_APP_ATTEST_KEY_ROTATION_PERCENT", raw)
		if got := service.ConfigFromEnvironment().KeyRotationPercent; got != want {
			t.Fatalf("%q: %d, want %d", raw, got, want)
		}
	}
	included, excluded := false, false
	for i := 0; i < 200; i++ {
		account := string(rune('a'+i%26)) + string(rune('a'+i/26))
		switch cohort.KeyRotation(account, 50) {
		case "enabled":
			included = true
			if cohort.KeyRotation(account, 60) != "enabled" {
				t.Fatal("cohort shrank when percentage increased")
			}
		case "cohort_excluded":
			excluded = true
		}
	}
	if !included || !excluded {
		t.Fatal("partial cohort did not split accounts")
	}
	if cohort.KeyRotation("", 100) == "enabled" {
		t.Fatal("anonymous account rotated")
	}
}
