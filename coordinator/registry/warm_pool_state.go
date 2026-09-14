package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/warmpool"
)

func (r *Registry) RecordWarmPoolCapacityReject(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.RecordEvent(model, warmpool.CapacityReject, time.Now())
}

func (r *Registry) RecordWarmPoolQueueEnqueued(model string, depth int, oldestAge time.Duration) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.RecordQueuePressure(model, depth, oldestAge, time.Now())
}

func (r *Registry) RecordWarmPoolQueueCleared(model string) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.RecordQueuePressure(model, 0, 0, time.Now())
}

func (r *Registry) RecordWarmPoolQueueTimeout(model string, age time.Duration) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.RecordQueuePressure(model, 1, age, time.Now())
}

func (r *Registry) RecordWarmPoolTTFTMiss(model string, duration time.Duration) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.RecordEvent(model, warmpool.TTFTMiss, time.Now())
}

func (r *Registry) RecordWarmPoolSpeculativeStarted(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.RecordEvent(model, warmpool.SpeculativeStarted, time.Now())
}

func (r *Registry) RecordWarmPoolSpeculativeWon(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.RecordEvent(model, warmpool.SpeculativeWon, time.Now())
}

func (r *Registry) RecordWarmPoolColdDispatch(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.RecordEvent(model, warmpool.ColdDispatch, time.Now())
}

func (r *Registry) RecordWarmPoolLoadResult(model string, success bool, duration time.Duration) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.RecordLoad(model, success, duration, time.Now())
}
