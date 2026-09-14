package registry

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/faultstate"
)

var faultFixtureClocks sync.Map

// Each fixture clock is bound before any provider attaches. Only owned state
// timestamps change; registry liveness still uses real heartbeat timestamps.
func newClockedFaultRegistry(t *testing.T) *Registry {
	t.Helper()
	r := New(testLogger())
	offset := &atomic.Int64{}
	r.faults = faultstate.NewWithClock[*Provider](r.logger, func() time.Time { return time.Now().Add(time.Duration(offset.Load())) })
	faultFixtureClocks.Store(r, offset)
	t.Cleanup(func() { faultFixtureClocks.Delete(r) })
	return r
}
func withFaultFixtureTime(r *Registry, at time.Time, fn func()) {
	clock, ok := faultFixtureClocks.Load(r)
	if !ok {
		panic("fault fixture requires construction clock")
	}
	offset := clock.(*atomic.Int64)
	old := offset.Swap(int64(time.Until(at)))
	defer offset.Store(old)
	fn()
}
func advanceFaultFixtureTime(r *Registry, d time.Duration) {
	clock, ok := faultFixtureClocks.Load(r)
	if !ok {
		panic("fault fixture requires construction clock")
	}
	clock.(*atomic.Int64).Add(int64(d))
}
