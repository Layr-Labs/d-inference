package inference_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type faultAttributionFixture struct {
	owner *serverFixture

	latch      *backend.Latch
	evidence   *retry.TerminalEvidence
	current    retry.AttemptFailure
	pending    *registry.PendingRequest
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
	srv.observation.SetDatadog(dd)

	const model = "fault-attribution-model"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	first := registerHeartbeatedProvider(
		t, srv, "fault-attribution-paged", model, &paged)
	second := registerHeartbeatedProvider(
		t, srv, "fault-attribution-contiguous", model, &contiguous)
	return faultAttributionFixture{
		owner:      srv,
		latch:      srv.NewBackendLatch(),
		evidence:   &retry.TerminalEvidence{},
		collector:  collector,
		firstFault: first,
		second:     second,
		model:      model,
	}
}

func (f *faultAttributionFixture) providerError(
	t *testing.T,
	provider *registry.Provider,
	msg protocol.InferenceErrorMessage,
) {
	t.Helper()
	f.pending = &registry.PendingRequest{
		RequestID:  msg.RequestID,
		ProviderID: provider.ID,
		Model:      f.model,
	}
	_, sticky := f.evidence.Select(retry.NewTerminalFailure(f.current.Message, backend.Slot{}), false)
	f.latch.Note(provider, f.pending, sticky)
	f.current = f.evidence.Observe(provider, f.model, msg, 0, f.latch)
	f.pending = nil
}

func (f *faultAttributionFixture) assertFinalFault(
	t *testing.T,
	wantProvider, wantBackend string,
) {
	t.Helper()
	failure, sticky := f.evidence.Select(retry.NewTerminalFailure(f.current.Message, backend.Slot{}), false)
	status, reason, _, dominance := retry.ResolveTerminal(failure, sticky, retry.TerminalPolicy{})
	if status != http.StatusInternalServerError ||
		reason != "dispatch_exhausted" ||
		dominance !=
			retry.GenuineFault {
		t.Fatalf(
			"final HTTP selection = (%d, %q, %v), want sticky provider 500",
			status, reason, dominance)
	}
	if !failure.Slot().Matches(wantProvider, f.model) ||
		failure.Slot().Attribution().Backend != wantBackend {
		t.Fatalf(
			"terminal attribution = %+v, want provider=%q model=%q backend=%q",
			failure.Slot(), wantProvider, f.model, wantBackend)
	}

	attr := failure.Slot().Attribution()
	f.owner.NewMetrics().BackendOutcome(f.model, attr, infermetrics.ClassifyOutcomeByCode(status))
	if err := f.owner.observation.Datadog().Statsd.Flush(); err != nil {
		t.Fatalf("flush request outcome: %v", err)
	}
	outcomes := findMetrics(f.collector.drain(), infermetrics.RequestOutcomeMetric)
	if len(outcomes) != 1 {
		t.Fatalf("request outcomes = %v, want one", outcomes)
	}
	if !strings.Contains(outcomes[0], "class:"+infermetrics.ORProvider5xx) ||
		!strings.Contains(outcomes[0], backend.TagKey+
			wantBackend) {
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
		f.pending = &registry.PendingRequest{
			RequestID:  "survivor-content",
			ProviderID: f.second.ID,
			Model:      f.model,
		}
		f.latch.Note(f.second, f.pending, false)
		f.evidence.Observe(f.firstFault, f.model, genuineInternalFaultMessage(), 0, f.latch)

		attr := f.latch.Resolve(f.pending, true, true)
		if attr.Backend != registry.KVBackendContiguous {
			t.Fatalf(
				"live winner backend = %q, want %q",
				attr.Backend, registry.KVBackendContiguous)
		}
		f.owner.NewMetrics().BackendOutcome(f.model, attr, infermetrics.ORSuccess)
		if err := f.owner.observation.Datadog().Statsd.Flush(); err != nil {
			t.Fatalf("flush success outcome: %v", err)
		}
		outcomes := findMetrics(f.collector.drain(), infermetrics.RequestOutcomeMetric)
		if len(outcomes) != 1 ||
			!strings.Contains(outcomes[0], "class:"+infermetrics.ORSuccess) ||
			!strings.Contains(
				outcomes[0], backend.TagKey+
					registry.KVBackendContiguous) {
			t.Fatalf(
				"winning-content outcome = %v, want contiguous success",
				outcomes)
		}
	})

	t.Run("neutral survivor cannot replace loser fault", func(t *testing.T) {
		f := newFaultAttributionFixture(t)
		f.pending = &registry.PendingRequest{
			RequestID:  "survivor-deadline",
			ProviderID: f.second.ID,
			Model:      f.model,
		}
		f.latch.Note(f.second, f.pending, false)
		f.evidence.Observe(f.firstFault, f.model, genuineInternalFaultMessage(), 0, f.latch)
		f.current = f.evidence.Observe(f.second, f.model, deadlineUnreachableMessage(), 0, f.latch)
		f.pending = nil

		f.assertFinalFault(
			t, f.firstFault.ID, registry.KVBackendPaged)
	})
}
