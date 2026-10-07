package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

func (r *Registry) RecordWarmPoolCapacityReject(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.RecordEvent(model, warmplan.WarmPoolEventCapacityReject, time.Now())
}

func (r *Registry) RecordWarmPoolQueueEnqueued(model string, depth int, oldestAge time.Duration) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.recordQueuePressure(model, depth, oldestAge, time.Now())
}

func (r *Registry) RecordWarmPoolQueueCleared(model string) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.recordQueuePressure(model, 0, 0, time.Now())
}

func (r *Registry) RecordWarmPoolQueueTimeout(model string, age time.Duration) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.recordQueuePressure(model, 1, age, time.Now())
}

func (r *Registry) RecordWarmPoolTTFTMiss(model string, duration time.Duration) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.RecordEvent(model, warmplan.WarmPoolEventTTFTMiss, time.Now())
}

func (r *Registry) RecordWarmPoolSpeculativeStarted(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.RecordEvent(model, warmplan.WarmPoolEventSpeculativeStarted, time.Now())
}

func (r *Registry) RecordWarmPoolSpeculativeWon(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.RecordEvent(model, warmplan.WarmPoolEventSpeculativeWon, time.Now())
}

func (r *Registry) RecordWarmPoolColdDispatch(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.RecordEvent(model, warmplan.WarmPoolEventColdDispatch, time.Now())
}

func (r *Registry) RecordWarmPoolLoadResult(model string, success bool, duration time.Duration) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.RecordLoad(model, success, duration, time.Now())
}
