package api

import (
	"testing"
	"time"
)

func TestParseNetworkSeriesWindow(t *testing.T) {
	t.Parallel()

	tests := []struct {
		input         string
		wantLabel     string
		wantDuration  time.Duration
		wantBucket    time.Duration
		wantSupported bool
	}{
		{"", "30m", 30 * time.Minute, time.Minute, true},
		{"30m", "30m", 30 * time.Minute, time.Minute, true},
		{"24h", "24h", 24 * time.Hour, 30 * time.Minute, true},
		{"1d", "24h", 24 * time.Hour, 30 * time.Minute, true},
		{"7d", "7d", 7 * 24 * time.Hour, 4 * time.Hour, true},
		{"30d", "30d", 30 * 24 * time.Hour, 12 * time.Hour, true},
		{"15m", "", 0, 0, false},
		{"31d", "", 0, 0, false},
	}

	for _, test := range tests {
		test := test
		t.Run(test.input, func(t *testing.T) {
			t.Parallel()
			spec, ok := parseNetworkSeriesWindow(test.input)
			if ok != test.wantSupported {
				t.Fatalf("supported = %v, want %v", ok, test.wantSupported)
			}
			if spec.label != test.wantLabel || spec.duration != test.wantDuration || spec.bucketSize != test.wantBucket {
				t.Fatalf("spec = %+v, want label=%q duration=%s bucket=%s", spec, test.wantLabel, test.wantDuration, test.wantBucket)
			}
		})
	}
}
