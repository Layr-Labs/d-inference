package api

import "time"

// admissionPressureGate buffers preflight scaling signals while an alias's
// input floor is unresolved. The request may release them only after both quota
// and balance admission succeed; terminal rejections discard the pending work.
// This object belongs to one handler goroutine, not shared registry state.
type admissionPressureGate struct {
	s        *Server
	admitted bool
	pending  []func()
}

func (g *admissionPressureGate) record(action func()) {
	if g.admitted {
		action()
	} else {
		g.pending = append(g.pending, action)
	}
}

func (g *admissionPressureGate) capacity(model string) {
	g.record(func() {
		g.s.registry.RecordWarmPoolCapacityReject(model)
		g.s.triggerWarmPool()
	})
}

func (g *admissionPressureGate) ttftMiss(model string, threshold time.Duration) {
	g.record(func() {
		g.s.registry.RecordWarmPoolTTFTMiss(model, threshold)
		g.s.triggerWarmPool()
	})
}

func (g *admissionPressureGate) admit() {
	g.admitted = true
	pending := g.pending
	g.pending = nil
	for _, action := range pending {
		action()
	}
}
