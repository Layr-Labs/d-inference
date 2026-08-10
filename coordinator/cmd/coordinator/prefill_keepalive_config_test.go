package main

import (
	"testing"
	"time"
)

func TestDefaultPrefillKeepaliveLeavesOpenRouterTimeoutMargin(t *testing.T) {
	const observedSilentUpstreamTimeout = 10 * time.Second

	if defaultPrefillKeepaliveInterval != 5*time.Second {
		t.Fatalf(
			"default prefill keepalive = %s, want 5s",
			defaultPrefillKeepaliveInterval,
		)
	}
	if defaultPrefillKeepaliveInterval >= observedSilentUpstreamTimeout {
		t.Fatalf(
			"default prefill keepalive %s races observed timeout %s",
			defaultPrefillKeepaliveInterval,
			observedSilentUpstreamTimeout,
		)
	}
}
