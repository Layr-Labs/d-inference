// Package configswitch owns the cached health-ejection policy switch.
package configswitch

import (
	"strings"
	"sync/atomic"
)

const HealthEjectionEnvKey = "EIGENINFERENCE_HEALTH_EJECTION"

// Switch caches configuration independently of subsequent environment changes.
type Switch struct {
	enabled atomic.Bool
}

func New(raw string) *Switch {
	s := &Switch{}
	s.Store(Parse(raw))
	return s
}

// Parse disables ejection only for an explicit off/0/false/no value.
func Parse(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "off", "0", "false", "no":
		return false
	default:
		return true
	}
}

func (s *Switch) Load() bool { return s.enabled.Load() }

func (s *Switch) Store(enabled bool) { s.enabled.Store(enabled) }

func (s *Switch) Swap(enabled bool) bool { return s.enabled.Swap(enabled) }
