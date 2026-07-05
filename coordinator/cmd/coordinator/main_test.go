package main

import (
	"math"
	"testing"
)

// TestParseAPNsEnforceAfter verifies the security-relevant contract: unset is the
// safe grace default, a valid RFC3339 value parses, and a NON-EMPTY malformed
// value returns an error (so the caller fails startup instead of silently keeping
// the fleet in grace — a hidden enforcement downgrade).
func TestParseAPNsEnforceAfter(t *testing.T) {
	t.Setenv("APNS_ENFORCE_AFTER", "")
	if d, err := parseAPNsEnforceAfter(); err != nil || !d.IsZero() {
		t.Fatalf("unset should be (zero,nil); got (%v,%v)", d, err)
	}

	t.Setenv("APNS_ENFORCE_AFTER", "2026-06-11T17:00:00Z")
	if d, err := parseAPNsEnforceAfter(); err != nil || d.IsZero() {
		t.Fatalf("valid RFC3339 should parse to a non-zero time; got (%v,%v)", d, err)
	}

	t.Setenv("APNS_ENFORCE_AFTER", "tomorrow-ish")
	if _, err := parseAPNsEnforceAfter(); err == nil {
		t.Fatal("a malformed value must return an error, not silently fall back to grace")
	}
}

// TestValidateTTFTOccupancyAlpha pins the env bounds: valid values apply,
// negatives clamp to 0 (term off), and unparseable / non-finite / absurd values
// are rejected so the caller keeps the safe default 0.
func TestValidateTTFTOccupancyAlpha(t *testing.T) {
	cases := []struct {
		in       string
		wantVal  float64
		wantOK   bool
		wantName string
	}{
		{"0", 0, true, "zero (behavior-neutral default)"},
		{"45", 45, true, "typical configured value"},
		{"1000000", 1_000_000, true, "exactly the max"},
		{" 12.5 ", 12.5, true, "trimmed float"},
		{"-1", 0, true, "negative clamps to 0"},
		{"1000000.0001", 0, false, "above max → reject"},
		{"1e9", 0, false, "absurd → reject"},
		{"NaN", 0, false, "non-finite → reject"},
		{"Inf", 0, false, "non-finite → reject"},
		{"abc", 0, false, "unparseable → reject"},
		{"", 0, false, "empty → reject"},
	}
	for _, c := range cases {
		gotVal, gotOK := validateTTFTOccupancyAlpha(c.in)
		if gotOK != c.wantOK || gotVal != c.wantVal {
			t.Errorf("validateTTFTOccupancyAlpha(%q) [%s] = (%v, %v), want (%v, %v)",
				c.in, c.wantName, gotVal, gotOK, c.wantVal, c.wantOK)
		}
	}
}

// TestValidateTTFTDeadlineBaseMs pins the env range [1000, 120000] ms; values
// outside it (or unparseable/non-finite) are rejected so the caller keeps the
// verified ~10s default.
func TestValidateTTFTDeadlineBaseMs(t *testing.T) {
	cases := []struct {
		in      string
		wantVal float64
		wantOK  bool
	}{
		{"10000", 10000, true},
		{"1000", 1000, true},       // lower bound inclusive
		{"120000", 120000, true},   // upper bound inclusive
		{"5000", 5000, true},       //
		{"999", 0, false},          // below min
		{"120000.5", 0, false},     // above max
		{"0", 0, false},            // zero rejected
		{"-1", 0, false},           // negative rejected
		{"NaN", 0, false},          // non-finite
		{"Inf", 0, false},          // non-finite
		{"not-a-number", 0, false}, // unparseable
		{"", 0, false},             // empty
	}
	for _, c := range cases {
		gotVal, gotOK := validateTTFTDeadlineBaseMs(c.in)
		if gotOK != c.wantOK || gotVal != c.wantVal {
			t.Errorf("validateTTFTDeadlineBaseMs(%q) = (%v, %v), want (%v, %v)",
				c.in, gotVal, gotOK, c.wantVal, c.wantOK)
		}
	}
	// Sanity: the bounds constants are coherent.
	if minTTFTDeadlineBaseMs >= maxTTFTDeadlineBaseMs || math.IsNaN(maxTTFTOccupancyAlpha) {
		t.Fatal("TTFT bound constants are incoherent")
	}
}
