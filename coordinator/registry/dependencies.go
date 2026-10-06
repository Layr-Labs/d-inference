package registry

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityquote"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotledger"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/eviction"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/kvbackend"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/modelindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerdrain"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/queuedrain"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/shortlist"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/transport"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/versionmemo"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

// QueueClaims is the consumer side of a request queue. Requeue returns an
// unassigned claim to the same queue, retaining FIFO and cancellation fences.
type QueueClaims interface {
	PopNextFresh(model string) *QueuedRequest
	RequeueFront(*QueuedRequest)
	PrepareProviderAssignment(*QueuedRequest, *Provider, func()) (*ProviderAssignment, bool)
}

// Dependencies retains independently owned transport, throughput, queue-consumer
// and reservation-preparation components. Factories bind each adapter to the
// actual component owned by this registry, not to a second state implementation.
type Dependencies struct {
	ProviderDirectory     *ProviderDirectory
	AppAttestNow          func() time.Time
	ModelCounts           *modelindex.Counts
	ConnectionOrigin      func(string, time.Time) *connectiontime.Origin
	ConnectionLifecycle   func(*ConnectionLifecycle) ConnectionMaintenance
	EvictionGrace         *eviction.Grace
	ProviderPersistence   func(string, *ProviderPersistence) ProviderPersistenceOperations
	ModelCommands         func(string, ModelCommandTransport) ModelCommandTransport
	AutopilotState        func(string) *autopilotstate.State
	AutopilotSender       func(string, protocol.ModelAutopilotMessage) error
	AutopilotControl      autopilotcontrol.Factory[*Provider]
	AutopilotDemand       *autopilot.DemandTracker
	CapacitySamples       func(string) *capacityvalue.SampleHistory
	CapacityQuotes        *capacityquote.Tracker
	PlanOrder             func() *shortlist.Order
	HeartbeatNow          func() time.Time
	AutopilotEvents       *autopilotledger.Events
	IdentityGates         *identitygate.Directory
	PendingLoads          *pendingload.Ledger
	ModelAdvertisements   *modelindex.Index[*Provider]
	ModelCandidates       ModelCandidates
	ModelMembership       func(string) *modelindex.Membership
	Cache                 CacheDependencies
	Connections           providerwrite.Factory
	ProviderDrains        func(string) *providerdrain.Authority
	ServiceRetirements    func(string) *serviceretirement.Ledger
	ServiceReservations   func(string) *ServiceReservations
	Throughput            *TPSRegistry
	PerformanceProfiles   *performance.Catalog
	DeadlineProfiles      *deadline.Catalog
	DeadlinePosture       func(string, *deadline.Posture) deadline.PosturePolicy
	Measurements          func(string) *measurements.History
	KVBackends            func(string) *kvbackend.History
	TransportMeasurements func(string) *transport.History
	QualityPolicy         *quality.Policy
	VersionMemo           *versionmemo.Memo[[]int]
	QueueClaims           func(*RequestQueue) QueueClaims
	Reservations          func(*ReservationPlanner) ReservationPreparation
	DrainSuppression      *queuedrain.Suppressor
	WarmPlanning          WarmPlanningFactory
	WarmHistory           func(string) *warmplan.WorkHistory
	WarmLifecycle         func(string) warmplan.LoadLifecycle
	SwapPlanning          SwapPlanningFactory
	ModelLoadPlanning     func(*ModelLoadPlanner) ModelLoadPlanning
}

func NewWithDependencies(logger *slog.Logger, deps Dependencies) *Registry {
	r := newRegistry(logger)
	r.bindProviderDirectory(deps.ProviderDirectory)
	r.appAttestClock = deps.AppAttestNow
	if deps.ModelCounts != nil {
		r.modelCounts = deps.ModelCounts
	}
	r.connectionOriginFactory = deps.ConnectionOrigin
	if deps.EvictionGrace != nil {
		r.evictionGrace = deps.EvictionGrace
	}
	r.providerPersistenceFactory = deps.ProviderPersistence
	r.modelCommandFactory = deps.ModelCommands
	r.autopilotStateFactory = deps.AutopilotState
	r.autopilotSender = deps.AutopilotSender
	r.autopilotControlFactory = deps.AutopilotControl
	r.autopilotDemand = deps.AutopilotDemand
	r.capacitySamplesFactory = deps.CapacitySamples
	r.planOrderFactory = deps.PlanOrder
	if deps.CapacityQuotes != nil {
		r.capacityQuotes = deps.CapacityQuotes
	}
	if deps.HeartbeatNow != nil {
		r.heartbeatNow = deps.HeartbeatNow
	}
	if deps.AutopilotEvents != nil {
		r.autopilotEvents = deps.AutopilotEvents
	}
	if deps.IdentityGates != nil {
		r.gates = deps.IdentityGates
	}
	if deps.PendingLoads != nil {
		r.pendingLoads = deps.PendingLoads
	}
	r.modelIndex.configured = deps.ModelAdvertisements
	r.modelCandidates = deps.ModelCandidates
	r.modelMembershipFactory = deps.ModelMembership
	r.cacheDependencies = deps.Cache
	r.cacheRouting = newCacheRoutingTrackerWithDependencies(defaultCacheRoutingTTL, defaultCacheRoutingMaxHolders, deps.Cache)
	r.warmPlanningFactory = deps.WarmPlanning
	r.warmHistoryFactory = deps.WarmHistory
	r.warmLifecycleFactory = deps.WarmLifecycle
	r.measurementsFactory = deps.Measurements
	r.kvBackendsFactory = deps.KVBackends
	r.transportFactory = deps.TransportMeasurements
	r.deadlinePostureFactory = deps.DeadlinePosture
	loadPlanner := &ModelLoadPlanner{registry: r}
	r.modelLoadPlanner = loadPlanner
	if deps.ModelLoadPlanning != nil {
		r.modelLoadPlanner = deps.ModelLoadPlanning(loadPlanner)
	}
	if deps.DrainSuppression != nil {
		r.drainSuppress = deps.DrainSuppression
	}
	r.connections = deps.Connections
	r.providerDrainFactory = deps.ProviderDrains
	r.serviceRetirementFactory = deps.ServiceRetirements
	r.serviceReservationsFactory = deps.ServiceReservations
	if r.connections == nil {
		r.connections = providerwrite.SocketFactory{}
	}
	if deps.Throughput != nil {
		r.tpsRegistry = deps.Throughput
	}
	if deps.PerformanceProfiles != nil {
		r.performanceProfiles = deps.PerformanceProfiles
	}
	if deps.DeadlineProfiles != nil {
		r.deadlineProfiles = deps.DeadlineProfiles
	}
	if deps.QualityPolicy != nil {
		r.qualityPolicy = deps.QualityPolicy
	}
	if deps.VersionMemo != nil {
		r.versionMemo = deps.VersionMemo
	}
	r.queueClaimsFactory = deps.QueueClaims
	r.queueClaims = r.claimsForQueue(r.queue)
	r.configureSwapPlanning(deps.SwapPlanning)
	planner := &ReservationPlanner{registry: r}
	r.reservationPlanner = planner
	if deps.Reservations != nil {
		r.reservations = deps.Reservations(planner)
	}
	lifecycle := &ConnectionLifecycle{registry: r}
	r.connectionLifecycle = lifecycle
	if deps.ConnectionLifecycle != nil {
		r.connectionLifecycle = deps.ConnectionLifecycle(lifecycle)
	}
	return r
}

func (r *Registry) claimsForQueue(queue *RequestQueue) QueueClaims {
	if queue == nil {
		return nil
	}
	if r.queueClaimsFactory != nil {
		return r.queueClaimsFactory(queue)
	}
	return queue
}

func (r *Registry) queueConsumer() (*RequestQueue, QueueClaims) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	claims := r.queueClaims
	if claims == nil && r.queue != nil {
		claims = r.queue
	}
	return r.queue, claims
}
