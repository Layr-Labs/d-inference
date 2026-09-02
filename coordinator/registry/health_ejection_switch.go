package registry

import (
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// health_ejection_switch.go — the process-wide health-ejection kill switch.
//
// EIGENINFERENCE_HEALTH_EJECTION is parsed exactly once at package init and
// cached in an atomic so the routing gate (providerPassesRoutingGatesLockedEx,
// once per provider per scan) reads a single atomic load instead of
// os.Getenv + ToLower + TrimSpace. A running process cannot observe a change
// to its own environment, so this is behavior-identical to the former per-call
// read; the only writer after init is the test hook below.

// healthEjectionEnvKey is the kill-switch variable; off/0/false/no disable.
const healthEjectionEnvKey = "EIGENINFERENCE_HEALTH_EJECTION"

var healthEjectionSwitch = func() *atomic.Bool {
	var b atomic.Bool
	b.Store(parseHealthEjectionEnv(os.Getenv(healthEjectionEnvKey)))
	return &b
}()

// parseHealthEjectionEnv maps the raw environment value to the switch state:
// off/0/false/no (case-insensitive, whitespace-trimmed) disable; anything
// else — including unset — enables.
func parseHealthEjectionEnv(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "off", "0", "false", "no":
		return false
	default:
		return true
	}
}

// setHealthEjectionEnabledForTest flips the cached kill switch for the
// duration of a test and restores the previous state on cleanup. It replaces
// t.Setenv(healthEjectionEnvKey, ...) — which no longer has any effect after
// init — as the way tests exercise the disabled path.
func setHealthEjectionEnabledForTest(t testing.TB, enabled bool) {
	t.Helper()
	prev := healthEjectionSwitch.Swap(enabled)
	t.Cleanup(func() { healthEjectionSwitch.Store(prev) })
}
