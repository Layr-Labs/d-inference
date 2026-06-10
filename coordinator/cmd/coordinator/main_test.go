package main

import "testing"

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
