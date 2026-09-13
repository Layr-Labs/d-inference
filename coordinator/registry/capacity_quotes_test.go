package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// --- helpers ---------------------------------------------------------------

const seqTestModel = "mlx-community/Qwen3.5-9B-Instruct-4bit" // testRegisterMessage's model

func seqHeartbeat(seq uint64, activeTokens int64) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		BackendCapacity: &protocol.BackendCapacity{
			CapacitySeq: seq,
			Slots: []protocol.BackendSlotCapacity{
				{Model: seqTestModel, State: "running", ActiveTokens: activeTokens},
			},
		},
	}
}

func heartbeatActiveTokens(t *testing.T, p *Provider) int64 {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity == nil || len(p.BackendCapacity.Slots) == 0 {
		t.Fatal("provider has no applied BackendCapacity slots")
	}
	return p.BackendCapacity.Slots[0].ActiveTokens
}

func setQuoteCapable(p *Provider) {
	p.mu.Lock()
	p.capacityQuoteCapable = true
	p.mu.Unlock()
}

// attachTestWriter wires a real WebSocket writer onto a registered provider
// and returns the client end for reading the frames the coordinator sends.
func attachTestWriter(t *testing.T, p *Provider) *websocket.Conn {
	t.Helper()
	serverConn, clientConn := testWebSocketPair(t)
	p.mu.Lock()
	p.Conn = serverConn
	p.writer = newProviderWriter(serverConn)
	p.mu.Unlock()
	t.Cleanup(p.closeWriterNow)
	return clientConn
}

func readProbeFrame(t *testing.T, conn *websocket.Conn) protocol.CapacityProbeMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("reading probe frame: %v", err)
	}
	var probe protocol.CapacityProbeMessage
	if err := json.Unmarshal(data, &probe); err != nil {
		t.Fatalf("unmarshal probe frame %s: %v", data, err)
	}
	if probe.Type != protocol.TypeCapacityProbe {
		t.Fatalf("frame type = %q, want %q", probe.Type, protocol.TypeCapacityProbe)
	}
	return probe
}

func testQuote(quoteID string, admissible bool, p90ms float64) *protocol.CapacityQuoteMessage {
	q := &protocol.CapacityQuoteMessage{
		Type:                 protocol.TypeCapacityQuote,
		QuoteID:              quoteID,
		CapacitySeq:          1,
		AdmissibleNow:        admissible,
		TTFTP50MS:            p90ms / 2,
		TTFTP90MS:            p90ms,
		AvailableTokenBudget: 50_000,
		Confidence:           protocol.CapacityConfidenceHigh,
	}
	if !admissible {
		q.RejectionReason = protocol.RejectionReasonTokenBudget
	}
	return q
}

// collectOutcomes drains the probe channel until it closes.
func collectOutcomes(t *testing.T, ch <-chan QuoteOutcome) map[string]QuoteOutcome {
	t.Helper()
	got := make(map[string]QuoteOutcome)
	deadline := time.After(5 * time.Second)
	for {
		select {
		case o, ok := <-ch:
			if !ok {
				return got
			}
			got[o.ProviderID] = o
		case <-deadline:
			t.Fatalf("outcome channel did not close; got %v", got)
		}
	}
}

func trackerLen(r *Registry) int {
	r.capacityQuotes.mu.Lock()
	defer r.capacityQuotes.mu.Unlock()
	return len(r.capacityQuotes.pending)
}

// --- capacity_seq heartbeat gate -------------------------------------------

// A reordered event heartbeat (lower seq decoded after a higher one) must not
// regress applied capacity state, but must still count as liveness.
func TestHeartbeatCapacitySeqStaleDiscard(t *testing.T) {
	reg := New(testLogger())
	reg.Register("p1", nil, testRegisterMessage())
	p := reg.GetProvider("p1")

	reg.Heartbeat("p1", seqHeartbeat(2, 100))
	if got := heartbeatActiveTokens(t, p); got != 100 {
		t.Fatalf("active tokens after seq 2 = %d, want 100", got)
	}

	// Age LastHeartbeat so the liveness-only advance is observable.
	past := time.Now().Add(-time.Minute)
	p.mu.Lock()
	p.LastHeartbeat = past
	p.mu.Unlock()

	// Lower seq: the whole capacity application is discarded.
	reg.Heartbeat("p1", seqHeartbeat(1, 999))
	if got := heartbeatActiveTokens(t, p); got != 100 {
		t.Fatalf("active tokens after stale seq 1 = %d, want 100 (discarded)", got)
	}
	// Equal seq is stale too (a duplicate must not re-apply).
	reg.Heartbeat("p1", seqHeartbeat(2, 777))
	if got := heartbeatActiveTokens(t, p); got != 100 {
		t.Fatalf("active tokens after duplicate seq 2 = %d, want 100 (discarded)", got)
	}

	p.mu.Lock()
	lastHB, seq := p.LastHeartbeat, p.capacitySeq
	p.mu.Unlock()
	if !lastHB.After(past) {
		t.Fatal("stale heartbeat did not advance LastHeartbeat (liveness must survive the discard)")
	}
	if seq != 2 {
		t.Fatalf("capacitySeq = %d, want 2 (stale frames must not move the high-water mark)", seq)
	}

	// A genuinely newer frame applies again.
	reg.Heartbeat("p1", seqHeartbeat(3, 300))
	if got := heartbeatActiveTokens(t, p); got != 300 {
		t.Fatalf("active tokens after seq 3 = %d, want 300", got)
	}
}

// Seq 0 / omitted is a legacy provider: every heartbeat applies exactly as
// today and the session never becomes quote-capable.
func TestHeartbeatCapacitySeqLegacyPassthrough(t *testing.T) {
	reg := New(testLogger())
	reg.Register("p1", nil, testRegisterMessage())
	p := reg.GetProvider("p1")

	reg.Heartbeat("p1", seqHeartbeat(0, 100))
	reg.Heartbeat("p1", seqHeartbeat(0, 50)) // "regression" is fine: legacy has no ordering
	if got := heartbeatActiveTokens(t, p); got != 50 {
		t.Fatalf("active tokens = %d, want 50 (legacy heartbeats always apply)", got)
	}
	if p.capacityQuoteReady() {
		t.Fatal("legacy provider (seq 0) marked quote-capable")
	}
}

// The first seq > 0 heartbeat latches the session quote-capable.
func TestHeartbeatCapacitySeqMarksQuoteCapable(t *testing.T) {
	reg := New(testLogger())
	reg.Register("p1", nil, testRegisterMessage())
	p := reg.GetProvider("p1")

	if p.capacityQuoteReady() {
		t.Fatal("fresh session must not be quote-capable before any seq heartbeat")
	}
	reg.Heartbeat("p1", seqHeartbeat(1, 10))
	if !p.capacityQuoteReady() {
		t.Fatal("seq 1 heartbeat did not mark the session quote-capable")
	}
}

// A reconnect creates a fresh *Provider (in prod each WS even gets a fresh
// UUID; same-ID reuse goes through Disconnect first — Register refuses to
// replace a live entry), so the seq high-water mark resets with the object
// and the new connection's restarted counter is accepted.
func TestHeartbeatCapacitySeqResetsOnReconnect(t *testing.T) {
	reg := New(testLogger())
	first := reg.Register("p1", nil, testRegisterMessage())
	reg.Heartbeat("p1", seqHeartbeat(5, 100))

	reg.Disconnect("p1")
	second := reg.Register("p1", nil, testRegisterMessage())
	if first == second {
		t.Fatal("re-register returned the same *Provider; per-connection seq state would leak")
	}
	if second.capacityQuoteReady() {
		t.Fatal("fresh connection inherited quote-capable state")
	}
	// The restarted counter's seq 1 would be stale against the OLD
	// connection's 5; against the fresh object it must apply.
	reg.Heartbeat("p1", seqHeartbeat(1, 42))
	if got := heartbeatActiveTokens(t, second); got != 42 {
		t.Fatalf("active tokens after reconnect seq 1 = %d, want 42 (seq must reset per connection)", got)
	}
}

// --- quote correlation ------------------------------------------------------

// A provider must not be able to answer another provider's probe: the quote is
// dropped and the entry stays registered for the bound provider's own answer.
func TestHandleCapacityQuoteWrongProviderDropped(t *testing.T) {
	reg := New(testLogger())
	deliveries := make(chan quoteDelivery, 1)
	reg.capacityQuotes.add("q1", &pendingQuote{
		providerID: "pA",
		expiresAt:  time.Now().Add(time.Minute),
		deliver:    deliveries,
	})

	reg.HandleCapacityQuote("pB", testQuote("q1", true, 500))
	select {
	case d := <-deliveries:
		t.Fatalf("forged quote from pB delivered: %+v", d)
	default:
	}
	if trackerLen(reg) != 1 {
		t.Fatal("forged quote consumed the real provider's entry")
	}

	// Unknown quote_id: dropped without touching the registered entry.
	reg.HandleCapacityQuote("pA", testQuote("q-unknown", true, 500))
	if trackerLen(reg) != 1 {
		t.Fatal("unknown quote_id mutated the tracker")
	}

	// The bound provider's own answer resolves it.
	reg.HandleCapacityQuote("pA", testQuote("q1", true, 500))
	select {
	case d := <-deliveries:
		if d.providerID != "pA" || d.quote == nil || !d.quote.AdmissibleNow {
			t.Fatalf("delivery = %+v, want pA's admissible quote", d)
		}
	default:
		t.Fatal("bound provider's quote was not delivered")
	}
	if trackerLen(reg) != 0 {
		t.Fatal("resolved entry not removed from tracker")
	}
}

// --- probe fanout -----------------------------------------------------------

// Happy path: quote-capable entries are probed on the data lane with a
// bucketed shape; an affirmative quote confirms, a negative demotes, and a
// legacy entry is never probed (it stays unconfirmed mid-tier). The plan is
// already re-ranked when the outcome channel closes.
func TestProbePlanCandidatesHappyPath(t *testing.T) {
	reg := New(testLogger())
	model := "quote-happy-model"
	for i := range 4 {
		planTestProvider(t, reg, fmt.Sprintf("hq%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("quote-happy", 500, 256)
	pr.Model = model
	winner, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if winner == nil || winner.ID != "hq00" || plan.Len() != 3 {
		t.Fatalf("setup: winner=%v plan.Len()=%d, want hq00 with 3 alternates", winner, plan.Len())
	}

	p01, p02 := reg.GetProvider("hq01"), reg.GetProvider("hq02")
	setQuoteCapable(p01)
	setQuoteCapable(p02)
	// hq03 stays legacy: no quote-capable mark, no writer. If it were
	// (wrongly) probed, its dead writer would surface as a third outcome.
	conn01 := attachTestWriter(t, p01)
	conn02 := attachTestWriter(t, p02)

	ch := reg.ProbePlanCandidates(plan, CapacityProbeShape{
		Model:             model,
		PromptTokens:      700,
		MaxOutputTokens:   256,
		DeadlineRemaining: 3 * time.Second,
	}, 2*time.Second)

	probe01 := readProbeFrame(t, conn01)
	if probe01.Model != model || probe01.QuoteID == "" {
		t.Fatalf("probe = %+v, want model %q and a quote_id", probe01, model)
	}
	if probe01.PromptTokensBucket != 1024 {
		t.Fatalf("prompt bucket = %d, want 1024 (700 rounded UP to the 512 bucket)", probe01.PromptTokensBucket)
	}
	if probe01.DeadlineRemainingMS != 3000 {
		t.Fatalf("deadline_remaining_ms = %d, want 3000", probe01.DeadlineRemainingMS)
	}
	probe02 := readProbeFrame(t, conn02)
	if probe02.QuoteID == probe01.QuoteID {
		t.Fatal("two probes shared a quote_id; correlation would cross-resolve")
	}

	reg.HandleCapacityQuote("hq01", testQuote(probe01.QuoteID, true, 800))
	reg.HandleCapacityQuote("hq02", testQuote(probe02.QuoteID, false, 0))

	outcomes := collectOutcomes(t, ch)
	if len(outcomes) != 2 {
		t.Fatalf("outcomes = %v, want exactly hq01+hq02 (legacy hq03 must not be probed)", outcomes)
	}
	if o := outcomes["hq01"]; o.Quote == nil || !o.Quote.AdmissibleNow || o.Timeout || o.SendFailed {
		t.Fatalf("hq01 outcome = %+v, want affirmative quote", o)
	}
	if o := outcomes["hq02"]; o.Quote == nil || o.Quote.AdmissibleNow || o.Quote.RejectionReason != protocol.RejectionReasonTokenBudget {
		t.Fatalf("hq02 outcome = %+v, want negative quote with rejection reason", o)
	}

	// Plan already re-ranked: confirmed hq01 first, unprobed legacy hq03 mid,
	// demoted hq02 last (channel close happens-after the collector's writes).
	wantOrder := []string{"hq01", "hq03", "hq02"}
	for i, want := range wantOrder {
		if got := plan.entries[i].view.ProviderID; got != want {
			t.Fatalf("entry[%d] = %q, want %q (confirmed → legacy → demoted)", i, got, want)
		}
	}
	if !plan.entries[0].view.Confirmed || plan.entries[0].view.QuoteTTFTP90 != 800*time.Millisecond {
		t.Fatalf("confirmed entry = %+v, want quote p90 800ms stored", plan.entries[0].view)
	}
	id, p90, ok := plan.BestConfirmedBackup()
	if !ok || id != "hq01" || p90 != 800*time.Millisecond {
		t.Fatalf("BestConfirmedBackup = (%q, %v, %v), want (hq01, 800ms, true)", id, p90, ok)
	}
	if trackerLen(reg) != 0 {
		t.Fatal("tracker entries leaked after all probes resolved")
	}
}

// A silent provider settles as Timeout at window expiry and is demoted; its
// tracker entry is reclaimed so a late quote is dropped.
func TestProbePlanCandidatesTimeoutOutcome(t *testing.T) {
	reg := New(testLogger())
	model := "quote-timeout-model"
	for i := range 2 {
		planTestProvider(t, reg, fmt.Sprintf("to%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("quote-timeout", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)

	silent := reg.GetProvider("to01")
	setQuoteCapable(silent)
	conn := attachTestWriter(t, silent)

	ch := reg.ProbePlanCandidates(plan, CapacityProbeShape{Model: model, PromptTokens: 100, MaxOutputTokens: 64}, 150*time.Millisecond)
	probe := readProbeFrame(t, conn) // probe arrives; we never answer

	outcomes := collectOutcomes(t, ch)
	if o := outcomes["to01"]; !o.Timeout || o.Quote != nil || o.SendFailed {
		t.Fatalf("outcome = %+v, want Timeout", o)
	}
	if !plan.entries[0].view.Demoted {
		t.Fatal("silent entry was not demoted")
	}
	if trackerLen(reg) != 0 {
		t.Fatal("timed-out probe left its tracker entry behind")
	}
	// A quote arriving after the window resolves nothing (entry reclaimed).
	reg.HandleCapacityQuote("to01", testQuote(probe.QuoteID, true, 100))
	if _, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatal("late quote confirmed a timed-out entry")
	}
}

// A dead writer (queue full / stopped — here: no writer at all) settles as
// SendFailed immediately, well inside the window.
func TestProbePlanCandidatesSendFailure(t *testing.T) {
	reg := New(testLogger())
	model := "quote-sendfail-model"
	for i := range 2 {
		planTestProvider(t, reg, fmt.Sprintf("sf%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("quote-sendfail", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)
	setQuoteCapable(reg.GetProvider("sf01")) // quote-capable but writerless

	start := time.Now()
	outcomes := collectOutcomes(t, reg.ProbePlanCandidates(plan, CapacityProbeShape{Model: model, PromptTokens: 100, MaxOutputTokens: 64}, 5*time.Second))
	if o := outcomes["sf01"]; !o.SendFailed || o.Timeout || o.Quote != nil {
		t.Fatalf("outcome = %+v, want SendFailed", o)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("send failure took %v to settle; must not wait out the window", elapsed)
	}
	if !plan.entries[0].view.Demoted {
		t.Fatal("send-failed entry was not demoted")
	}
}

// Disconnect resolves the disconnected provider's outstanding waiters as
// SendFailed instead of letting them burn the full quote window.
func TestDisconnectResolvesQuoteWaiters(t *testing.T) {
	reg := New(testLogger())
	model := "quote-disconnect-model"
	for i := range 2 {
		planTestProvider(t, reg, fmt.Sprintf("dc%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("quote-disconnect", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)

	target := reg.GetProvider("dc01")
	setQuoteCapable(target)
	conn := attachTestWriter(t, target)

	ch := reg.ProbePlanCandidates(plan, CapacityProbeShape{Model: model, PromptTokens: 100, MaxOutputTokens: 64}, 10*time.Second)
	readProbeFrame(t, conn) // frame is on the wire → the entry is registered

	start := time.Now()
	reg.Disconnect("dc01")
	outcomes := collectOutcomes(t, ch)
	if o := outcomes["dc01"]; !o.SendFailed || o.Timeout {
		t.Fatalf("outcome = %+v, want SendFailed from disconnect", o)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("disconnect resolution took %v; waiters must not ride out the 10s window", elapsed)
	}
	if trackerLen(reg) != 0 {
		t.Fatal("disconnect left tracker entries behind")
	}
}

// --- plan re-ranking --------------------------------------------------------

// Confirm/Demote re-rank the unconsumed tail into confirmed → unprobed →
// demoted tiers with ascending scan cost inside each tier, regardless of
// quote arrival order; BestConfirmedBackup returns the cheapest confirmed
// entry's quoted p90.
func TestDispatchPlanConfirmDemoteOrdering(t *testing.T) {
	reg := New(testLogger())
	model := "plan-rank-model"
	for i := range 5 {
		planTestProvider(t, reg, fmt.Sprintf("rk%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("plan-rank", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr) // winner rk00; entries rk01..rk04

	// Confirmations arrive out of cost order: the costlier rk03 first.
	plan.ConfirmEntry("rk03", testQuote("q3", true, 900))
	plan.ConfirmEntry("rk01", testQuote("q1", true, 400))
	plan.DemoteEntry("rk02")

	wantOrder := []string{"rk01", "rk03", "rk04", "rk02"}
	for i, want := range wantOrder {
		if got := plan.entries[i].view.ProviderID; got != want {
			t.Fatalf("entry[%d] = %q, want %q (confirmed by cost → unprobed → demoted)", i, got, want)
		}
	}
	id, p90, ok := plan.BestConfirmedBackup()
	if !ok || id != "rk01" || p90 != 400*time.Millisecond {
		t.Fatalf("BestConfirmedBackup = (%q, %v, %v), want (rk01, 400ms, true)", id, p90, ok)
	}

	// Demotion outranks a prior confirmation (it is always the later signal).
	plan.DemoteEntry("rk01")
	if id, _, _ := plan.BestConfirmedBackup(); id != "rk03" {
		t.Fatalf("after demoting rk01, BestConfirmedBackup = %q, want rk03", id)
	}

	// Consumed entries are history: confirming one must not resurrect it.
	e, okNext := plan.nextEntry() // consumes rk03 (best remaining)
	if !okNext || e.view.ProviderID != "rk03" {
		t.Fatalf("nextEntry = %+v, want rk03 (confirmed tier first)", e.view)
	}
	plan.ConfirmEntry("rk03", testQuote("q3b", true, 100))
	if id, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatalf("BestConfirmedBackup = %q after consuming the only confirmed entry, want none", id)
	}
}

// The probe collector (Confirm/Demote/BestConfirmedBackup) and the dispatch
// loop (ReserveNextFromPlan) touch one plan concurrently; run under -race.
func TestDispatchPlanConcurrentQuoteAndConsume(t *testing.T) {
	reg := New(testLogger())
	model := "plan-race-model"
	for i := range 10 {
		planTestProvider(t, reg, fmt.Sprintf("rc%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("plan-race", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if plan.Len() != dispatchPlanMaxAlternates {
		t.Fatalf("plan.Len() = %d, want %d", plan.Len(), dispatchPlanMaxAlternates)
	}
	ids := make([]string, 0, plan.Len())
	plan.mu.Lock()
	for _, e := range plan.entries {
		ids = append(ids, e.view.ProviderID)
	}
	plan.mu.Unlock()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { // probe collector: quotes land while the consumer drains
		defer wg.Done()
		for i := range 300 {
			id := ids[i%len(ids)]
			switch i % 3 {
			case 0:
				plan.ConfirmEntry(id, testQuote("qr", true, float64(100+i)))
			case 1:
				plan.DemoteEntry(id)
			default:
				plan.BestConfirmedBackup()
			}
		}
	}()
	go func() { // dispatch loop: consume the plan to exhaustion
		defer wg.Done()
		for i := 0; ; i++ {
			cpr := planTestRequest(fmt.Sprintf("plan-race-consume-%d", i), 500, 256)
			cpr.Model = model
			p, _, skips := reg.ReserveNextFromPlan(cpr, plan)
			if p != nil {
				p.RemovePending(cpr.RequestID)
				reg.SetProviderIdle(p.ID)
				continue
			}
			if len(skips) > 0 && skips[len(skips)-1].Reason == PlanSkipExhausted {
				return
			}
		}
	}()
	wg.Wait()

	if got := plan.Remaining(); got != 0 {
		t.Fatalf("plan.Remaining() = %d after exhaustion, want 0", got)
	}
}

// --- hedge governor snapshot ------------------------------------------------

// HedgeGovernorSnapshot is a point-in-time advisory read: idle-spread from the
// same computation as the Phase-0 shadow signal, per-model queued demand,
// fleet-wide loaded-idle slots, and the dual-path capacity-signal bit that
// tells the governor whether those inputs are meaningful at all.
func TestHedgeGovernorSnapshot(t *testing.T) {
	reg := New(testLogger())
	model := "governor-snap-model"
	for i := range 3 {
		planTestProvider(t, reg, fmt.Sprintf("gv%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("governor-snap", 200, 128)
	pr.Model = model

	idleAlt, depth, idleSlots, signals := reg.HedgeGovernorSnapshot(model, pr, "gv00")
	if !idleAlt {
		t.Fatal("idleAlternativeExists = false with two loaded-idle non-excluded providers")
	}
	if depth != 0 {
		t.Fatalf("modelQueueDepth = %d, want 0", depth)
	}
	if idleSlots != 3 {
		t.Fatalf("fleetIdleSlots = %d, want 3 (every registered slot is loaded-idle)", idleSlots)
	}
	if !signals {
		t.Fatal("capacitySignalsAvailable = false on a fully-reporting fleet")
	}

	// Occupying one provider's slot removes it from the idle count.
	busy := reg.GetProvider("gv01")
	busy.mu.Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 1
	busy.mu.Unlock()
	if _, _, idleSlots, _ := reg.HedgeGovernorSnapshot(model, pr, "gv00"); idleSlots != 2 {
		t.Fatalf("fleetIdleSlots = %d after occupying gv01, want 2", idleSlots)
	}

	// A different model served by no reporting provider gets no signal bit:
	// the reporting fleet for gv-model says nothing about it.
	if _, _, _, signals := reg.HedgeGovernorSnapshot("some-other-model", pr); signals {
		t.Fatal("capacitySignalsAvailable = true for a model no reporting provider serves")
	}
}

// A capacity-silent (all-legacy) fleet returns structural zeros — the same
// shape as saturation — so it must be distinguishable via
// capacitySignalsAvailable=false, letting the api bypass the governor and
// keep today's unconditional 50% hedge (plan decision 3: legacy fleets keep
// current behavior).
func TestHedgeGovernorSnapshotCapacitySilentFleet(t *testing.T) {
	reg := New(testLogger())
	model := "governor-legacy-model"
	for i := range 3 {
		p := planTestProvider(t, reg, fmt.Sprintf("lg%02d", i), model, 0)
		p.mu.Lock()
		p.BackendCapacity = nil // legacy: no capacity reporting at all
		p.mu.Unlock()
	}
	pr := planTestRequest("governor-legacy", 200, 128)
	pr.Model = model

	_, _, idleSlots, signals := reg.HedgeGovernorSnapshot(model, pr, "lg00")
	if idleSlots != 0 {
		t.Fatalf("fleetIdleSlots = %d on a non-reporting fleet, want 0", idleSlots)
	}
	if signals {
		t.Fatal("capacitySignalsAvailable = true on an all-legacy fleet")
	}

	// One provider proving quote capability flips the fleet into governed
	// mode even before its next capacity snapshot lands.
	setQuoteCapable(reg.GetProvider("lg01"))
	if _, _, _, signals := reg.HedgeGovernorSnapshot(model, pr, "lg00"); !signals {
		t.Fatal("capacitySignalsAvailable = false with a quote-capable provider serving the model")
	}
}

// TestQuoteTrackerSweepIsTimeGated pins the P1 fix on add's expiry sweep:
// the >1024 size trigger only makes a sweep worth CONSIDERING — the time
// gate (quoteTrackerSweepInterval) must hold sustained over-threshold
// insertion to at most one full scan per window, instead of rescanning the
// whole map under t.mu on every add.
func TestQuoteTrackerSweepIsTimeGated(t *testing.T) {
	var tr quoteTracker
	live := time.Now().Add(time.Hour) // unexpired: a sweep removes nothing
	for i := range 1025 {
		tr.add(fmt.Sprintf("q%04d", i), &pendingQuote{expiresAt: live})
	}
	if tr.sweeps != 0 {
		t.Fatalf("sweeps=%d while filling to the threshold, want 0", tr.sweeps)
	}

	// First over-threshold add: the zero-value lastSweep passes the time
	// gate, so exactly one sweep runs.
	tr.add("over-0", &pendingQuote{expiresAt: live})
	if tr.sweeps != 1 {
		t.Fatalf("sweeps=%d after first over-threshold add, want 1", tr.sweeps)
	}

	// Sustained over-threshold insertion within the window: still one sweep.
	for i := range 64 {
		tr.add(fmt.Sprintf("over-%d", i+1), &pendingQuote{expiresAt: live})
	}
	if tr.sweeps != 1 {
		t.Fatalf("sweeps=%d after 64 in-window adds, want 1 (time-gated)", tr.sweeps)
	}

	// A full window elapses (clock seam: rewind lastSweep) — the next add
	// sweeps again, and the sweep still collects expired entries.
	tr.mu.Lock()
	tr.pending["expired-a"] = &pendingQuote{expiresAt: time.Now().Add(-time.Second)}
	tr.pending["expired-b"] = &pendingQuote{expiresAt: time.Now().Add(-time.Second)}
	tr.lastSweep = time.Now().Add(-2 * quoteTrackerSweepInterval)
	tr.mu.Unlock()
	tr.add("post-window", &pendingQuote{expiresAt: live})
	if tr.sweeps != 2 {
		t.Fatalf("sweeps=%d after the window elapsed, want 2", tr.sweeps)
	}
	tr.mu.Lock()
	_, expAlive := tr.pending["expired-a"]
	_, liveAlive := tr.pending["post-window"]
	tr.mu.Unlock()
	if expAlive || !liveAlive {
		t.Fatalf("post-window sweep: expired retained=%v live dropped=%v", expAlive, !liveAlive)
	}
}

// TestHedgeGovernorSnapshotQueueDepthFiltersIncompatibleWaiters pins the P2
// routing-compatibility filter on modelQueueDepth: a waiter that structurally
// cannot drain onto the capacity a public hedge would consume (exclusive
// self-route, or pinned to serials the request cannot use) must not suppress
// that hedge, while a plain public waiter still does.
func TestHedgeGovernorSnapshotQueueDepthFiltersIncompatibleWaiters(t *testing.T) {
	reg := New(testLogger())
	model := "governor-queue-filter-model"
	for i := range 2 {
		planTestProvider(t, reg, fmt.Sprintf("gq%02d", i), model, int64(i)*400)
	}
	pr := planTestRequest("governor-queue", 200, 128)
	pr.Model = model

	enqueue := func(id string, pending *PendingRequest) {
		t.Helper()
		if err := reg.Queue().Enqueue(&QueuedRequest{
			RequestID:  id,
			Model:      model,
			ResponseCh: make(chan *Provider, 1),
			Pending:    pending,
		}); err != nil {
			t.Fatalf("enqueue %s: %v", id, err)
		}
	}

	enqueue("w-self", &PendingRequest{RequestID: "w-self", Model: model, SelfRouteOnly: true, OwnerAccountID: "acct-A"})
	if _, depth, _, _ := reg.HedgeGovernorSnapshot(model, pr); depth != 0 {
		t.Fatalf("modelQueueDepth = %d with only a self-route-only waiter, want 0 (must not suppress a public hedge)", depth)
	}

	enqueue("w-serial", &PendingRequest{RequestID: "w-serial", Model: model, AllowedProviderSerials: []string{"SER-X"}})
	if _, depth, _, _ := reg.HedgeGovernorSnapshot(model, pr); depth != 0 {
		t.Fatalf("modelQueueDepth = %d with a non-overlapping serial-pinned waiter, want 0", depth)
	}

	enqueue("w-public", &PendingRequest{RequestID: "w-public", Model: model})
	if _, depth, _, _ := reg.HedgeGovernorSnapshot(model, pr); depth != 1 {
		t.Fatalf("modelQueueDepth = %d with a plain public waiter, want 1 (still suppresses)", depth)
	}

	// A request pinned to the SAME serial set demonstrably competes with the
	// pinned waiter — both count, plus the unconstrained public waiter.
	pinned := planTestRequest("governor-queue-pinned", 200, 128)
	pinned.Model = model
	pinned.AllowedProviderSerials = []string{"SER-X"}
	if _, depth, _, _ := reg.HedgeGovernorSnapshot(model, pinned); depth != 2 {
		t.Fatalf("modelQueueDepth = %d for an overlapping pinned request, want 2 (pinned + public waiters)", depth)
	}
}

// TestHedgeGovernorSnapshotExcludesPrivateOnlyIdleSlots pins the P2 hedge
// budget fix: an idle slot on a private-only provider serves exclusively its
// owner's self-route requests, cannot absorb displaced public demand, and so
// must not mint public hedge budget via fleetIdleSlots.
func TestHedgeGovernorSnapshotExcludesPrivateOnlyIdleSlots(t *testing.T) {
	reg := New(testLogger())
	model := "governor-private-model"
	planTestProvider(t, reg, "pub", model, 0)
	priv := planTestProvider(t, reg, "priv", model, 400)
	priv.mu.Lock()
	priv.PrivateOnly = true
	priv.mu.Unlock()

	pr := planTestRequest("governor-private", 200, 128)
	pr.Model = model
	if _, _, idleSlots, _ := reg.HedgeGovernorSnapshot(model, pr); idleSlots != 1 {
		t.Fatalf("fleetIdleSlots = %d, want 1 (idle private-only slot contributes zero)", idleSlots)
	}
}
