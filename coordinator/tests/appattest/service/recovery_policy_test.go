package service_test

import (
	"reflect"
	"testing"
	"time"

	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
)

func TestAppAttestAppleFailureRecoveryCadenceDoesNotAccelerateStorageFailures(t *testing.T) {
	for _, tc := range []struct {
		outcome string
		want    []time.Duration
	}{
		{"apple_error", []time.Duration{time.Minute, 5 * time.Minute, recovery.AssertionInterval, recovery.AssertionInterval}},
		{"apple_unavailable", []time.Duration{time.Minute, 5 * time.Minute, recovery.AssertionInterval, recovery.AssertionInterval}},
		{"storage_error", []time.Duration{time.Minute, 5 * time.Minute, time.Hour, time.Hour}},
	} {
		t.Run(tc.outcome, func(t *testing.T) {
			var got []time.Duration
			for failures := range tc.want {
				got = append(got, recovery.ExchangeRetryDelay(tc.outcome, failures))
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("delay=%v, want %v", got, tc.want)
			}
		})
	}
}
