package trustreuse

import (
	"os"
	"time"
)

// defaultTrustReuseWindow is how long a successful FULL live MDM verification is
// honored for a NEW connection from the same device — without re-running the live
// MDM SecurityInfo round-trip — provided a fresh live SE challenge re-proves the
// SAME identity, binary, and good posture. It bounds the staleness of the MDM
// proof. Kept SHORT (Threat-Model #3): the reuse must not be able to span a
// SIP-disable reboot cycle (where a box reboots into Recovery, disables SIP, and
// reconnects), so a window comfortably under a realistic reboot+reconnect is used.
// Tightened from 10m to 5m once connection-continuity reuse (see
// trustReuseReconnectGapFromEnv) started covering the legitimate operational
// reconnect cases, so the pure wall-clock staleness bound can be stricter.
// Overridable via EIGENINFERENCE_TRUST_REUSE_WINDOW.
const defaultTrustReuseWindow = 5 * time.Minute

// Connection-continuity reuse (the "continuity" decision): a provider that was
// live-verified, stayed continuously connected and hardware-trusted (the
// coordinator advances a durable ContinuousCoverageUntil watermark while it
// observes the live SE-challenged connection), and reconnects after a
// coordinator-MEASURED offline gap of at most the reconnect-gap allowance may
// reuse its device evidence even when HardwareProofVerifiedAt has fallen out
// of the wall-clock window. SECURITY INVARIANT (Threat-Model T-036):
// SIP/Secure Boot can only change in RecoveryOS; entering and leaving Recovery
// on Apple Silicon (One True Recovery: manual power-button entry, credentialed
// csrutil/bputil, two boot transitions) takes >= ~3 minutes and drops any
// WebSocket, so a contiguous coordinator-measured offline gap <= 120s cannot
// span a posture flip. The gap is never provider-claimed. The 120s ceiling is
// therefore a HARD security bound: EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP
// values above it clamp DOWN (with a warning), never up.
const defaultTrustReuseReconnectGap = 90 * time.Second

const maxTrustReuseReconnectGap = 120 * time.Second

// ClockSkewTolerance is shared by device and application evidence coverage.
const ClockSkewTolerance = 2 * time.Minute

const clockSkewTolerance = ClockSkewTolerance

func newCache() *cache {
	return newCacheWithWindow(trustReuseWindowFromEnv())
}

// newCacheWithWindow pins the fast-skip freshness window verbatim.
// Tests use it to model a specific deployment window; production goes through
// newCache, i.e. the reviewed 5-minute default (Threat-Model #3 /
// T-036: must not span a SIP-disable reboot cycle) or the operator's
// EIGENINFERENCE_TRUST_REUSE_WINDOW override. The continuity reconnect-gap
// allowance always comes from the (hard-clamped) environment default.
func newCacheWithWindow(window time.Duration) *cache {
	if window <= 0 {
		window = defaultTrustReuseWindow
	}
	gap, _ := trustReuseReconnectGapFromEnv()
	return &cache{
		records:      make(map[string]record),
		reuseWindow:  window,
		reconnectGap: gap,
		now:          time.Now,
	}
}

// trustReuseWindowFromEnv reads EIGENINFERENCE_TRUST_REUSE_WINDOW (a Go duration,
// e.g. "45m"), falling back to defaultTrustReuseWindow when unset/invalid.
func trustReuseWindowFromEnv() time.Duration {
	if v := os.Getenv("EIGENINFERENCE_TRUST_REUSE_WINDOW"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return defaultTrustReuseWindow
}

// trustReuseReconnectGapFromEnv reads EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP
// (a Go duration), falling back to defaultTrustReuseReconnectGap when
// unset/invalid, and hard-clamps the result into [0, maxTrustReuseReconnectGap].
// The 120s ceiling is the RecoveryOS-physics security bound (see the constant
// docs above): values above it clamp DOWN, reported via the second return so
// the caller can log a warning. A zero allowance disables continuity reuse.
func trustReuseReconnectGapFromEnv() (time.Duration, bool) {
	gap := defaultTrustReuseReconnectGap
	if v := os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			gap = d
		}
	}
	if gap < 0 {
		gap = 0
	}
	if gap > maxTrustReuseReconnectGap {
		return maxTrustReuseReconnectGap, true
	}
	return gap, false
}
