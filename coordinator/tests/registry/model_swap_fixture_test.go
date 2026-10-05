package registry_test

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/swapplan"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

var swapFixtures sync.Map

type swapPlanFixture struct {
	controller *swapplan.Controller
	claims     *recordingSwapClaims
	clock      func() time.Time
	mu         sync.Mutex
	pending    int
	timer      *trailingTimerStub
	afterScan  func(string)
}

func newSwapRegistry(t *testing.T) *production.Registry {
	t.Helper()
	f := &swapPlanFixture{clock: time.Now}
	r := newWarmRegistryWithDeps(t, func(deps *production.Dependencies) {
		deps.SwapPlanning = func(deps swapplan.Dependencies) *swapplan.Controller {
			deps.Now = func() time.Time { return f.clock() }
			deps.AfterFunc = f.schedule
			deps.Claims = func(gate *swapplan.Gate) swapplan.Claims {
				f.claims = &recordingSwapClaims{Gate: gate}
				return f.claims
			}
			f.controller = swapplan.New(deps)
			return f.controller
		}
		deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
			return &swapReservationPreparation{planner: planner, fixture: f}
		}
	})
	swapFixtures.Store(r, f)
	t.Cleanup(func() { swapFixtures.Delete(r) })
	return r
}

func swapFixtureFor(r *production.Registry) *swapPlanFixture {
	f, ok := swapFixtures.Load(r)
	if !ok {
		panic("registry has no retained swap planning components")
	}
	return f.(*swapPlanFixture)
}

func (f *swapPlanFixture) schedule(wait time.Duration, fn func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pending++
	callback := func() {
		f.mu.Lock()
		f.pending--
		f.mu.Unlock()
		fn()
	}
	if f.timer != nil {
		f.timer.waits = append(f.timer.waits, wait)
		f.timer.fire = append(f.timer.fire, callback)
	} else {
		time.AfterFunc(wait, callback)
	}
}

func (f *swapPlanFixture) trailingArmed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pending != 0
}

type recordingSwapClaims struct {
	*swapplan.Gate
	mu   sync.Mutex
	runs int
	last time.Time
}

func (g *recordingSwapClaims) Claim(now time.Time) (bool, time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	allowed, wait := g.Gate.Claim(now)
	if allowed {
		g.runs++
		g.last = now
	}
	return allowed, wait
}

func (g *recordingSwapClaims) planRuns() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.runs
}

func (g *recordingSwapClaims) lastClaim() time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.last
}

type swapReservationPreparation struct {
	planner *production.ReservationPlanner
	fixture *swapPlanFixture
}

func (p *swapReservationPreparation) Prepare(model string, pending *production.PendingRequest, excludeIDs ...string) *production.PreparedReservation {
	prepared := p.planner.Prepare(model, pending, excludeIDs...)
	// This same immutable scan retains the actual Registry read lease while the
	// transport/heartbeat regression pauses before handing it to commit.
	if p.fixture.afterScan != nil {
		p.fixture.afterScan(model)
	}
	return prepared
}
