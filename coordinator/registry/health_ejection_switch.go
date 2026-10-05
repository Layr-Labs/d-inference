package registry

import (
	"os"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/configswitch"
)

// health_ejection_switch.go — the process-wide health-ejection kill switch.
//
// EIGENINFERENCE_HEALTH_EJECTION is parsed exactly once at package init and
// cached in an atomic so the routing gate (providerPassesRoutingGatesLockedEx,
// once per provider per scan) reads a single atomic load instead of
// os.Getenv + ToLower + TrimSpace. Later environment changes do not alter the
// cached policy; the process-wide switch is initialized once here.

// healthEjectionEnvKey is the kill-switch variable; off/0/false/no disable.
const healthEjectionEnvKey = configswitch.HealthEjectionEnvKey

var healthEjectionSwitch = configswitch.New(os.Getenv(healthEjectionEnvKey))
