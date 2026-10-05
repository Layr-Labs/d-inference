package routingsim_test

import (
	"container/heap"
	"fmt"
	"io"
	"log/slog"
	"math"
	"math/rand"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
)

// The closed-loop simulation feeds routing results back into fleet state. A
// provider that ReserveProviderEx selects serves the request, releases the
// reservation, and reports a new measurement through Registry.Heartbeat, the
// same ingest path that production uses. Idle providers keep sending
// heartbeats with unchanged values. The tests run inside testing/synctest, so
// time.Now in the registry reads the virtual clock and hours of simulated
// traffic take seconds of real time.

const (
	loopModel = "mlx-community/Qwen3.5-9B-Instruct-4bit"

	// loopHeartbeatInterval is the provider's default baseline heartbeat
	// cadence (heartbeatIntervalSecs in the Swift provider configuration).
	// Providers also send an event heartbeat when a request starts or ends.
	loopHeartbeatInterval = 5 * time.Second
	// loopChallengeInterval is the coordinator's attestation challenge
	// cadence. It keeps every provider inside challengeFreshnessMaxAge.
	loopChallengeInterval = 5 * time.Minute

	// loopArrivalInterval and loopRequestsInFlight shape a steady stream.
	// Every request takes loopRequestServiceTime, which ends just before
	// the arrival loopRequestsInFlight intervals later. So exactly
	// loopRequestsInFlight-1 requests are in flight when a request arrives.
	// A fleet of loopRequestsInFlight providers then has exactly one idle
	// provider at each arrival. That keeps a feasible peer present at every
	// decision, which is the condition that excludes providers with unknown
	// evidence.
	loopArrivalInterval    = 2 * time.Second
	loopRequestsInFlight   = 20
	loopRequestServiceTime = loopRequestsInFlight*loopArrivalInterval - 500*time.Millisecond

	// loopProviderPublicKey is a valid base64 X25519 key, so the provider
	// passes the private-text gate. The simulation never encrypts with it.
	loopProviderPublicKey = "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw="

	loopPromptTokens    = 1000
	loopMaxOutputTokens = 2048
	loopPeerDecodeTPS   = 52.0
	loopPeerPrefillTPS  = 2000.0
	// loopMeasurementNoise is the relative spread of one request's measured
	// rate. Real per-request rates vary, so a provider's EWMA changes after
	// each request it serves.
	loopMeasurementNoise = 0.03
	// loopEWMAWeight is the weight of a new sample in the provider's EWMA.
	// The Swift provider uses 0.3 for decode
	// (provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Accounting.swift:161)
	// and for prefill (EngineV2Bridge+Measurements.swift, updatePrefillTpsEwma).
	loopEWMAWeight = 0.3
	// loopSlowRunTolerance ends a run of slow setup samples once the EWMA
	// is within this fraction of the slow rate.
	loopSlowRunTolerance = 0.01
)

// measurementPath selects how a simulated provider reports performance.
type measurementPath string

const (
	// legacyTelemetryPath reports only EWMA values. The coordinator dates a
	// value when it changes between two accepted reports.
	legacyTelemetryPath measurementPath = "legacy"
	// explicitMeasurementPath also reports performance_measurements with an
	// epoch, a sample count and a sample age (#1233).
	explicitMeasurementPath measurementPath = "explicit"
)

// loopProviderSpec describes one simulated provider.
type loopProviderSpec struct {
	id string
	// joinAt is the simulated time of registration, measured from the
	// start of the run.
	joinAt time.Duration
	// established providers start with dated measurements, as a provider
	// that has served work for a while. Other providers start with none.
	established bool
	// lastDecodeTPS and lastPrefillTPS, when positive, are the rates of the
	// provider's last requests before it became idle. Setup blends slow
	// samples into the EWMA, as the provider does, until the reported EWMA is
	// within loopSlowRunTolerance of this rate. One slow sample alone moves
	// an EWMA with weight 0.3 only part of the way.
	lastDecodeTPS  float64
	lastPrefillTPS float64
}

// loopScenario is one closed-loop run.
type loopScenario struct {
	name      string
	seed      int64
	path      measurementPath
	providers []loopProviderSpec
	// streamStart and duration bound the arrival stream.
	streamStart time.Duration
	duration    time.Duration
	// pauses are intervals with no arrivals.
	pauses []loopPause
}

type loopPause struct{ from, to time.Duration }

// loopProvider is the simulated provider state.
type loopProvider struct {
	spec     loopProviderSpec
	provider *registry.Provider
	joined   bool
	seq      uint64

	decodeEWMA, prefillEWMA float64
	ewmaInitialized         bool
	// Explicit measurement metadata.
	epoch                     string
	decodeCount, prefillCount int64
	lastSampleAt              time.Time

	inFlight map[string]struct{}

	// Starvation bookkeeping.
	idleSince  time.Time
	selections int
	maxWait    time.Duration
	// firstPick records the first selection in the measured window.
	firstPick     time.Time
	firstPickTPS  float64
	firstPickSeen bool
}

// loopProviderResult summarizes one provider after a run.
type loopProviderResult struct {
	ID           string
	Selections   int
	MaxIdleWait  time.Duration
	FirstPick    time.Duration // from the stream start; -1 when never picked
	FirstPickTPS float64
}

// loopResult summarizes a run.
type loopResult struct {
	Scenario   string
	Seed       int64
	Arrivals   int
	Unserved   int
	Providers  []loopProviderResult
	BusiestPct float64
	BusiestID  string
}

func (r loopResult) provider(id string) (loopProviderResult, bool) {
	for _, p := range r.Providers {
		if p.ID == id {
			return p, true
		}
	}
	return loopProviderResult{}, false
}

// String formats the per-provider table for test logs.
func (r loopResult) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "scenario=%s seed=%d arrivals=%d unserved=%d busiest=%s (%.1f%%)\n",
		r.Scenario, r.Seed, r.Arrivals, r.Unserved, r.BusiestID, r.BusiestPct)
	fmt.Fprintf(&b, "%-12s %10s %14s %14s %14s\n", "provider", "selections", "max_idle_wait", "first_pick", "first_pick_tps")
	for _, p := range r.Providers {
		first := "never"
		if p.FirstPick >= 0 {
			first = p.FirstPick.String()
		}
		fmt.Fprintf(&b, "%-12s %10d %14s %14s %14.1f\n", p.ID, p.Selections, p.MaxIdleWait, first, p.FirstPickTPS)
	}
	return b.String()
}

type loopEventKind int

// Events at the same instant run in this order, so a request that ends and
// a heartbeat that falls due are visible to an arrival at that instant.
const (
	eventJoin loopEventKind = iota
	eventCompletion
	eventHeartbeat
	eventChallenge
	eventArrival
)

type loopEvent struct {
	at       time.Time
	kind     loopEventKind
	order    int
	provider *loopProvider
	request  string
}

type loopEventQueue []*loopEvent

func (q loopEventQueue) Len() int { return len(q) }
func (q loopEventQueue) Less(i, j int) bool {
	if !q[i].at.Equal(q[j].at) {
		return q[i].at.Before(q[j].at)
	}
	if q[i].kind != q[j].kind {
		return q[i].kind < q[j].kind
	}
	return q[i].order < q[j].order
}
func (q loopEventQueue) Swap(i, j int) { q[i], q[j] = q[j], q[i] }
func (q *loopEventQueue) Push(x any)   { *q = append(*q, x.(*loopEvent)) }
func (q *loopEventQueue) Pop() any {
	old := *q
	n := len(old)
	e := old[n-1]
	*q = old[:n-1]
	return e
}

// loopSim is one run. It is not safe for concurrent use; the event loop is
// single-threaded so that the run is reproducible for a seed, except for the
// registry's own random choice between equivalent candidates.
type loopSim struct {
	t        *testing.T
	sc       loopScenario
	reg      *registry.Registry
	rng      *rand.Rand
	events   loopEventQueue
	order    int
	start    time.Time
	resumeAt time.Time

	providers []*loopProvider
	arrivals  int
	unserved  int
	nextReqID int
}

// runClosedLoop runs sc and returns its summary. The caller must be inside a
// synctest bubble.
func runClosedLoop(t *testing.T, sc loopScenario) loopResult {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	s := &loopSim{
		t:     t,
		sc:    sc,
		reg:   registry.New(logger),
		rng:   rand.New(rand.NewSource(sc.seed)),
		start: time.Now(),
	}
	for i, spec := range sc.providers {
		lp := &loopProvider{spec: spec, inFlight: map[string]struct{}{}, epoch: fmt.Sprintf("epoch-%d", i)}
		s.providers = append(s.providers, lp)
		s.push(s.start.Add(spec.joinAt), eventJoin, lp, "")
	}
	end := s.start.Add(sc.streamStart + sc.duration)
	for at := s.start.Add(sc.streamStart); at.Before(end); at = at.Add(loopArrivalInterval) {
		if !s.paused(at) {
			s.push(at, eventArrival, nil, "")
		}
	}
	for s.events.Len() > 0 {
		ev := heap.Pop(&s.events).(*loopEvent)
		if ev.at.After(end) {
			break
		}
		if d := ev.at.Sub(time.Now()); d > 0 {
			time.Sleep(d)
		}
		switch ev.kind {
		case eventJoin:
			s.join(ev.provider)
		case eventHeartbeat:
			s.heartbeat(ev.provider)
			s.push(time.Now().Add(loopHeartbeatInterval), eventHeartbeat, ev.provider, "")
		case eventChallenge:
			s.reg.RecordChallengeSuccess(ev.provider.spec.id)
			s.push(time.Now().Add(loopChallengeInterval), eventChallenge, ev.provider, "")
		case eventArrival:
			s.arrive()
		case eventCompletion:
			s.complete(ev.provider, ev.request)
		}
	}
	if d := end.Sub(time.Now()); d > 0 {
		time.Sleep(d)
	}
	now := time.Now()
	for _, lp := range s.providers {
		if lp.joined && len(lp.inFlight) == 0 {
			lp.noteWait(now, s.waitStart(lp))
		}
	}
	return s.result()
}

func (s *loopSim) push(at time.Time, kind loopEventKind, lp *loopProvider, request string) {
	s.order++
	heap.Push(&s.events, &loopEvent{at: at, kind: kind, order: s.order, provider: lp, request: request})
}

func (s *loopSim) paused(at time.Time) bool {
	for _, p := range s.sc.pauses {
		if !at.Before(s.start.Add(p.from)) && at.Before(s.start.Add(p.to)) {
			return true
		}
	}
	return false
}

// waitStart is when the provider's current idle wait began to count. Time
// before the stream starts, and time in a pause, is not starvation.
func (s *loopSim) waitStart(lp *loopProvider) time.Time {
	start := lp.idleSince
	if streamStart := s.start.Add(s.sc.streamStart); start.Before(streamStart) {
		start = streamStart
	}
	if start.Before(s.resumeAt) {
		start = s.resumeAt
	}
	return start
}

func (lp *loopProvider) noteWait(now, from time.Time) {
	if w := now.Sub(from); w > lp.maxWait {
		lp.maxWait = w
	}
}

// registerLoopProvider registers one provider on the routingsim default
// hardware and grants the attestation state that routing requires. The Swift
// provider registers without benchmark decode_tps or prefill_tps
// (CoordinatorClientCodec.encodeRegistration), so the message has neither.
// Challenge freshness comes from RecordChallengeSuccess in join.
func registerLoopProvider(reg *registry.Registry, id string) *registry.Provider {
	hw := routingsim.DefaultHardwareSpec()
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           hw.ChipName,
			ChipFamily:         hw.ChipFamily,
			ChipTier:           hw.ChipTier,
			MemoryGB:           hw.MemoryGB,
			MemoryAvailableGB:  float64(hw.MemoryGB),
			MemoryBandwidthGBs: hw.MemoryBandwidthGBs,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           hw.GPUCores,
		},
		Models:                  []protocol.ModelInfo{{ID: loopModel, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               loopProviderPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			SIPEnabled:           true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.Mu().Unlock()
	return p
}

func (s *loopSim) join(lp *loopProvider) {
	lp.provider = registerLoopProvider(s.reg, lp.spec.id)
	lp.joined = true
	lp.idleSince = time.Now()
	s.reg.RecordChallengeSuccess(lp.spec.id)
	if lp.spec.established {
		// Two setup reports with different values date the measurement at
		// the first report, as for a provider that has served before.
		lp.observe(loopPeerDecodeTPS*0.98, loopPeerPrefillTPS*0.98)
		s.heartbeat(lp)
		lp.observe(loopPeerDecodeTPS, loopPeerPrefillTPS)
		decode, prefill := loopPeerDecodeTPS, loopPeerPrefillTPS
		if lp.spec.lastDecodeTPS > 0 {
			decode = lp.spec.lastDecodeTPS
		}
		if lp.spec.lastPrefillTPS > 0 {
			prefill = lp.spec.lastPrefillTPS
		}
		for !withinTolerance(lp.decodeEWMA, decode) || !withinTolerance(lp.prefillEWMA, prefill) {
			lp.observe(decode, prefill)
		}
	}
	s.heartbeat(lp)
	// Offset each provider's baseline heartbeat inside the interval, so
	// providers do not all report at the same instant.
	offset := time.Duration(s.rng.Int63n(int64(loopHeartbeatInterval)))
	s.push(time.Now().Add(offset), eventHeartbeat, lp, "")
	s.push(time.Now().Add(loopChallengeInterval), eventChallenge, lp, "")
}

// observe blends one completed sample into the EWMAs as the Swift provider
// does: the first sample sets the value, later samples take loopEWMAWeight.
func (lp *loopProvider) observe(decode, prefill float64) {
	if lp.ewmaInitialized {
		decode = loopEWMAWeight*decode + (1-loopEWMAWeight)*lp.decodeEWMA
		prefill = loopEWMAWeight*prefill + (1-loopEWMAWeight)*lp.prefillEWMA
	}
	lp.decodeEWMA, lp.prefillEWMA, lp.ewmaInitialized = decode, prefill, true
	lp.decodeCount++
	lp.prefillCount++
	lp.lastSampleAt = time.Now()
}

func withinTolerance(value, target float64) bool {
	return math.Abs(value-target) <= loopSlowRunTolerance*target
}

func (s *loopSim) sample(truth float64) float64 {
	return truth * (1 + loopMeasurementNoise*(2*s.rng.Float64()-1))
}

func (s *loopSim) arrive() {
	now := time.Now()
	s.arrivals++
	if s.resumeAt.IsZero() || s.paused(now.Add(-loopArrivalInterval)) {
		// The first arrival after a pause starts the waiting clock again.
		s.resumeAt = now
	}
	s.nextReqID++
	id := fmt.Sprintf("req-%06d", s.nextReqID)
	pr := &registry.PendingRequest{
		RequestID:             id,
		Model:                 loopModel,
		EstimatedPromptTokens: loopPromptTokens,
		RequestedMaxTokens:    loopMaxOutputTokens,
		FirstContentDeadline:  now.Add(routingsim.TTFTDeadline(loopModel, loopPromptTokens)),
	}
	p, decision := s.reg.ReserveProviderEx(loopModel, pr)
	var chosen *loopProvider
	if p != nil {
		for _, lp := range s.providers {
			if lp.provider == p {
				chosen = lp
				break
			}
		}
	}
	for _, lp := range s.providers {
		if !lp.joined || len(lp.inFlight) > 0 {
			continue
		}
		lp.noteWait(now, s.waitStart(lp))
	}
	if chosen == nil {
		s.unserved++
		return
	}
	chosen.selections++
	if !chosen.firstPickSeen {
		chosen.firstPickSeen = true
		chosen.firstPick = now
		chosen.firstPickTPS = decision.EffectiveTPS
	}
	chosen.inFlight[id] = struct{}{}
	s.heartbeat(chosen)
	s.push(now.Add(loopRequestServiceTime), eventCompletion, chosen, id)
}

func (s *loopSim) complete(lp *loopProvider, id string) {
	delete(lp.inFlight, id)
	lp.provider.RemovePending(id)
	s.reg.SetProviderIdle(lp.spec.id)
	lp.observe(s.sample(loopPeerDecodeTPS), s.sample(loopPeerPrefillTPS))
	if len(lp.inFlight) == 0 {
		lp.idleSince = time.Now()
	}
	s.heartbeat(lp)
}

// heartbeat sends the provider's current state through Registry.Heartbeat.
func (s *loopSim) heartbeat(lp *loopProvider) {
	lp.seq++
	running := len(lp.inFlight)
	slotState, status := "idle", "idle"
	if running > 0 {
		slotState, status = "running", "serving"
	}
	var queued, partial int64
	slot := protocol.BackendSlotCapacity{
		Model:      loopModel,
		State:      slotState,
		NumRunning: running,
		Telemetry: &protocol.SlotTelemetry{
			QueuedPrefillTokens: &queued,
			PartialPrefillRows:  &partial,
		},
	}
	initialized := lp.ewmaInitialized
	slot.Telemetry.EWMAInitialized = &initialized
	if lp.ewmaInitialized {
		prefill := lp.prefillEWMA
		slot.ObservedDecodeTPS = lp.decodeEWMA
		slot.ObservedPrefillTPS = lp.prefillEWMA
		slot.Telemetry.IsolatedPrefillTPS = &prefill
	}
	if s.sc.path == explicitMeasurementPath {
		m := &protocol.PerformanceMeasurements{Epoch: lp.epoch}
		if lp.ewmaInitialized {
			age := time.Since(lp.lastSampleAt).Milliseconds()
			m.IsolatedPrefill = &protocol.PerformanceRateObservation{
				TokensPerSecond: lp.prefillEWMA, SampleCount: lp.prefillCount, SampleAgeMS: age,
			}
			m.Decode = &protocol.PerformanceRateObservation{
				TokensPerSecond: lp.decodeEWMA, SampleCount: lp.decodeCount, SampleAgeMS: age,
			}
		}
		slot.PerformanceMeasurements = m
	}
	model := loopModel
	msg := &protocol.HeartbeatMessage{
		Type:          protocol.TypeHeartbeat,
		Status:        status,
		ActiveModel:   &model,
		WarmModels:    []string{loopModel},
		SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{
			CapacitySeq:   lp.seq,
			TotalMemoryGB: float64(routingsim.DefaultHardwareSpec().MemoryGB),
			Slots:         []protocol.BackendSlotCapacity{slot},
		},
	}
	if !s.reg.Heartbeat(lp.spec.id, msg) {
		s.t.Fatalf("seed %d: heartbeat from %s was not accepted", s.sc.seed, lp.spec.id)
	}
}

func (s *loopSim) result() loopResult {
	r := loopResult{Scenario: s.sc.name, Seed: s.sc.seed, Arrivals: s.arrivals, Unserved: s.unserved}
	streamStart := s.start.Add(s.sc.streamStart)
	busiest := -1
	for _, lp := range s.providers {
		pr := loopProviderResult{ID: lp.spec.id, Selections: lp.selections, MaxIdleWait: lp.maxWait, FirstPick: -1}
		if lp.firstPickSeen {
			pr.FirstPick = lp.firstPick.Sub(streamStart)
			pr.FirstPickTPS = lp.firstPickTPS
		}
		if lp.selections > busiest {
			busiest = lp.selections
			r.BusiestID = lp.spec.id
		}
		r.Providers = append(r.Providers, pr)
	}
	sort.Slice(r.Providers, func(i, j int) bool { return r.Providers[i].ID < r.Providers[j].ID })
	if served := s.arrivals - s.unserved; served > 0 {
		r.BusiestPct = 100 * float64(busiest) / float64(served)
	}
	return r
}
