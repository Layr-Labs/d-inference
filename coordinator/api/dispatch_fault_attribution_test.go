package api

import (
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type faultAttributionFixture struct {
	dispatch   *dispatchState
	collector  *udpCollector
	firstFault *registry.Provider
	second     *registry.Provider
	model      string
}

func newFaultAttributionFixture(t *testing.T) faultAttributionFixture {
	t.Helper()
	srv, _, _ := billingTestServer(t)
	collector := newUDPCollector(t)
	t.Cleanup(collector.Close)
	dd := newTestDD(t, collector)
	t.Cleanup(dd.Close)
	srv.SetDatadog(dd)

	const model = "fault-attribution-model"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	first := registerHeartbeatedProvider(
		t, srv, "fault-attribution-paged", model, &paged)
	second := registerHeartbeatedProvider(
		t, srv, "fault-attribution-contiguous", model, &contiguous)
	return faultAttributionFixture{
		dispatch: &dispatchState{
			s:                srv,
			model:            model,
			consumerEndpoint: "/v1/chat/completions",
		},
		collector:  collector,
		firstFault: first,
		second:     second,
		model:      model,
	}
}

func (f faultAttributionFixture) providerError(
	t *testing.T,
	provider *registry.Provider,
	msg protocol.InferenceErrorMessage,
) {
	t.Helper()
	f.dispatch.provider = provider
	f.dispatch.pr = &registry.PendingRequest{
		RequestID:  msg.RequestID,
		ProviderID: provider.ID,
		Model:      f.model,
	}
	f.dispatch.noteServingSlot()
	f.dispatch.setLastInferenceError(provider, msg)
	f.dispatch.provider, f.dispatch.pr = nil, nil
}

func (f faultAttributionFixture) assertFinalFault(
	t *testing.T,
	wantProvider, wantBackend string,
) {
	t.Helper()
	failure, sticky := f.dispatch.terminalFailureForExhaustion()
	status, reason, _, dominance := f.dispatch.resolveDominantExhaustedStatus(
		failure, sticky)
	if status != http.StatusInternalServerError ||
		reason != "dispatch_exhausted" ||
		dominance != exhaustedGenuineFault {
		t.Fatalf(
			"final HTTP selection = (%d, %q, %v), want sticky provider 500",
			status, reason, dominance)
	}
	if failure.attribution.providerID != wantProvider ||
		failure.attribution.model != f.model ||
		failure.attribution.backend.Backend != wantBackend {
		t.Fatalf(
			"terminal attribution = %+v, want provider=%q model=%q backend=%q",
			failure.attribution, wantProvider, f.model, wantBackend)
	}

	attr := f.dispatch.exhaustedKVBackendAttribution(failure, sticky)
	f.dispatch.recordDispatchedRequestOutcome(
		attr, classifyOutcomeByCode(status))
	if err := f.dispatch.s.dd.Statsd.Flush(); err != nil {
		t.Fatalf("flush request outcome: %v", err)
	}
	outcomes := findMetrics(f.collector.drain(), metricRequestOutcome)
	if len(outcomes) != 1 {
		t.Fatalf("request outcomes = %v, want one", outcomes)
	}
	if !strings.Contains(outcomes[0], "class:"+orClassProvider5xx) ||
		!strings.Contains(outcomes[0], kvBackendTagKey+wantBackend) {
		t.Fatalf(
			"request outcome = %q, want provider_5xx attributed to %s",
			outcomes[0], wantBackend)
	}
}

func TestStickyFaultAttributionFollowsTerminalPrecedence(t *testing.T) {
	t.Run("500 then deadline", func(t *testing.T) {
		f := newFaultAttributionFixture(t)
		f.providerError(t, f.firstFault, genuineInternalFaultMessage())
		f.providerError(t, f.second, deadlineUnreachableMessage())
		f.assertFinalFault(t, f.firstFault.ID, registry.KVBackendPaged)
	})

	t.Run("deadline then 500", func(t *testing.T) {
		f := newFaultAttributionFixture(t)
		f.providerError(t, f.firstFault, deadlineUnreachableMessage())
		f.providerError(t, f.second, genuineInternalFaultMessage())
		f.assertFinalFault(t, f.second.ID, registry.KVBackendContiguous)
	})

	t.Run("later genuine fault replaces both", func(t *testing.T) {
		f := newFaultAttributionFixture(t)
		f.providerError(t, f.firstFault, genuineInternalFaultMessage())
		f.providerError(t, f.second, genuineInternalFaultMessage())
		f.assertFinalFault(t, f.second.ID, registry.KVBackendContiguous)
	})
}

func TestSpeculativeFaultLoserAttributionOrdering(t *testing.T) {
	t.Run("on-time winner owns success", func(t *testing.T) {
		f := newFaultAttributionFixture(t)
		f.dispatch.provider = f.second
		f.dispatch.pr = &registry.PendingRequest{
			RequestID:  "survivor-content",
			ProviderID: f.second.ID,
			Model:      f.model,
		}
		f.dispatch.noteServingSlot()
		f.dispatch.latchDeterministicLoser(
			f.firstFault, genuineInternalFaultMessage())

		attr := f.dispatch.kvBackendAttribution()
		if attr.Backend != registry.KVBackendContiguous {
			t.Fatalf(
				"live winner backend = %q, want %q",
				attr.Backend, registry.KVBackendContiguous)
		}
		f.dispatch.recordDispatchedRequestOutcome(attr, orClassSuccess)
		if err := f.dispatch.s.dd.Statsd.Flush(); err != nil {
			t.Fatalf("flush success outcome: %v", err)
		}
		outcomes := findMetrics(f.collector.drain(), metricRequestOutcome)
		if len(outcomes) != 1 ||
			!strings.Contains(outcomes[0], "class:"+orClassSuccess) ||
			!strings.Contains(
				outcomes[0], kvBackendTagKey+registry.KVBackendContiguous) {
			t.Fatalf(
				"winning-content outcome = %v, want contiguous success",
				outcomes)
		}
	})

	t.Run("neutral survivor cannot replace loser fault", func(t *testing.T) {
		f := newFaultAttributionFixture(t)
		f.dispatch.provider = f.second
		f.dispatch.pr = &registry.PendingRequest{
			RequestID:  "survivor-deadline",
			ProviderID: f.second.ID,
			Model:      f.model,
		}
		f.dispatch.noteServingSlot()
		f.dispatch.latchDeterministicLoser(
			f.firstFault, genuineInternalFaultMessage())
		f.dispatch.setLastInferenceError(
			f.second, deadlineUnreachableMessage())
		f.dispatch.provider, f.dispatch.pr = nil, nil

		f.assertFinalFault(
			t, f.firstFault.ID, registry.KVBackendPaged)
	})
}
