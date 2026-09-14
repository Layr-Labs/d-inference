package registry

import (
	"os"
	"strings"
	"sync/atomic"
)

// health_ejection_switch.go — the process-wide health-ejection kill switch.
//
// EIGENINFERENCE_HEALTH_EJECTION is parsed exactly once at package init and
// cached in an atomic so the routing gate (providerPassesRoutingGatesLockedEx,
// once per provider per scan) reads a single atomic load instead of
// os.Getenv + ToLower + TrimSpace. A running process cannot observe a change
// to its own environment, so this is behavior-identical to the former per-call
// read; the only writer after init is the test hook
// setHealthEjectionEnabledForTest (health_ejection_switch_test.go).

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

// healthEjectionEnabled is the kill switch. Default ON;
// EIGENINFERENCE_HEALTH_EJECTION set to off/0/false/no disables both gating and
// recording. The value is read from the environment ONCE at process start
// (health_ejection_switch.go): a process's environment cannot change underneath
// it, so the former per-call os.Getenv + ToLower/TrimSpace — evaluated once per
// provider per routing scan — never actually toggled anything live; it only
// cost ~3% of the fleet-scale scan. Tests flip it through
// setHealthEjectionEnabledForTest.
func healthEjectionEnabled() bool {
	return healthEjectionSwitch.Load()
}
