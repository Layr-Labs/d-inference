// Package queuewait retains the timeout timer used by a queue waiter.
package queuewait

import "time"

type Timer interface {
	Done() <-chan time.Time
	Stop() bool
}

type Clock interface {
	NewTimer(time.Duration) Timer
}

type WallClock struct{}
type wallTimer time.Timer

func (WallClock) NewTimer(wait time.Duration) Timer { return (*wallTimer)(time.NewTimer(wait)) }
func (t *wallTimer) Done() <-chan time.Time         { return (*time.Timer)(t).C }
func (t *wallTimer) Stop() bool                     { return (*time.Timer)(t).Stop() }
