package api

import "time"

// admissionPressureGate validates a deferred alias's selected floor and cost
// admission before recording demand. Admission runs once, including when the
// preflight will return a terminal 429, so eligible demand still drives scaling.
// This object belongs to one handler goroutine, not shared registry state.
type admissionPressureGate struct {
	s                        *Server
	admitted                 bool
	fixedBuildAfterAdmission bool
	admitRequest             func(model string) bool
}

func (g *admissionPressureGate) admit(model string) bool {
	if g.admitted {
		return true
	}
	if g.admitRequest != nil && !g.admitRequest(model) {
		return false
	}
	g.admitted = true
	return true
}

func (g *admissionPressureGate) capacity(model string) bool {
	if !g.admit(model) {
		return false
	}
	g.s.registry.RecordWarmPoolCapacityReject(model)
	g.s.triggerWarmPool()
	return true
}

func (g *admissionPressureGate) ttftMiss(model string, threshold time.Duration) bool {
	if !g.admit(model) {
		return false
	}
	g.s.registry.RecordWarmPoolTTFTMiss(model, threshold)
	g.s.triggerWarmPool()
	return true
}

// Only one build passes a deferred floor. Once cost admission selects it, a
// later fleet change must not switch to the other build after quota is charged.
func (g *admissionPressureGate) allowsAliasFallback() bool {
	return !g.fixedBuildAfterAdmission || !g.admitted
}
