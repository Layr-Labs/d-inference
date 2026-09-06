package main

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProfileSigningRequiredForTrust(t *testing.T) {
	tests := []struct {
		name          string
		minTrust      registry.TrustLevel
		allowUnsigned string
		want          bool
	}{
		{name: "hardware defaults required", minTrust: registry.TrustHardware, want: true},
		{name: "hardware explicit false remains required", minTrust: registry.TrustHardware, allowUnsigned: "false", want: true},
		{name: "hardware malformed bypass fails closed", minTrust: registry.TrustHardware, allowUnsigned: "tru", want: true},
		{name: "hardware explicit dev bypass", minTrust: registry.TrustHardware, allowUnsigned: " true ", want: false},
		{name: "self-signed does not require enrollment signing", minTrust: registry.TrustSelfSigned, want: false},
		{name: "no trust does not require enrollment signing", minTrust: registry.TrustNone, want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := profileSigningRequiredForTrust(tc.minTrust, tc.allowUnsigned); got != tc.want {
				t.Fatalf("profileSigningRequiredForTrust(%q, %q) = %v, want %v",
					tc.minTrust, tc.allowUnsigned, got, tc.want)
			}
		})
	}
}
