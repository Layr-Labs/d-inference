package dispatch

import (
	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type fixtureRequestOutcome struct {
	model string
	attr  KVBackendAttribution
	class string
}

type fixtureRouteOutcome struct {
	id      string
	attempt int
	model   string
	outcome *store.InferenceRouteOutcome
}

// Record the actual ownership boundary without reimplementing API cache or
// metrics policy. The shared attempt publisher still performs real claims and
// profile updates before these observations.
type fixtureOutcomeObserver struct {
	fixtureObserver
	requestOutcomes []fixtureRequestOutcome
	pending         []*registry.PendingRequest
	cacheTerminals  []*registry.PendingRequest
	routes          []fixtureRouteOutcome
}

func (o *fixtureOutcomeObserver) RequestOutcome(model string, attr KVBackendAttribution, class string) {
	o.requestOutcomes = append(o.requestOutcomes, fixtureRequestOutcome{model, attr, class})
}

func (o *fixtureOutcomeObserver) PendingOutcome(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	o.pending = append(o.pending, pr)
	attempt.PublishPendingOutcome(pr, outcome, o)
}

func (o *fixtureOutcomeObserver) CacheTerminal(pr *registry.PendingRequest) {
	o.cacheTerminals = append(o.cacheTerminals, pr)
}

func (o *fixtureOutcomeObserver) RouteOutcome(id string, index int, model string, outcome *store.InferenceRouteOutcome) {
	o.routes = append(o.routes, fixtureRouteOutcome{id, index, model, outcome})
	o.fixtureObserver.RouteOutcome(id, index, model, outcome)
}
