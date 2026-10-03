package api

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func deadlineFixtureWork(t testing.TB, s *Server, model string, count int) *protocol.PromptWork {
	t.Helper()
	status, ok := s.PromptArtifactStatus(model)
	if !ok || !status.ArtifactReady {
		t.Fatal("fixture artifact is not ready")
	}
	return &protocol.PromptWork{Version: protocol.PromptWorkVersion, Source: protocol.PromptWorkExact,
		PromptTokens: count, UpperBoundTokens: count, ModelArtifactHash: status.ModelAggregateSHA256,
		PromptContractID: status.PromptContractID}
}

func TestPromptWorkDeadlineReconcilesQualifiedInputTerm(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	t.Cleanup(s.Close)
	const heuristic = 3606
	fallback := s.FirstContentDeadline(model, heuristic)
	for _, count := range []int{5779, 1200} {
		work := deadlineFixtureWork(t, s, model, count)
		if got, want := s.promptWorkDeadline(model, model, fallback, work), s.FirstContentDeadline(model, count); got != want {
			t.Fatalf("count%d: deadline%v want%v", count, got, want)
		}
		if s.promptWorkDeadline(model, model, 0, work) != 0 {
			t.Fatal("qualified count enabled an exempt account")
		}
	}
	work := deadlineFixtureWork(t, s, model, 5000)
	work.Source, work.CalibrationID, work.UpperBoundTokens = protocol.PromptWorkCalibrated, "reviewed-fixture", 6000
	if got := s.promptWorkDeadline(model, model, fallback, work); got != fallback {
		t.Fatal("calibration uncertainty extended contractual SLA", got)
	}
	work = deadlineFixtureWork(t, s, model, 6000)
	const alias = "deadline-qualified-alias-fixture"
	if err := modelpolicy.SetFirstContentSLAsFromEnv(alias + "=20000:7"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = modelpolicy.SetFirstContentSLAsFromEnv(alias + "=off") })
	if got := s.promptWorkDeadline(alias, model, fallback, work); got != 61*time.Second {
		t.Fatal("qualified concrete count lost public alias SLA", got)
	}
}

func TestPromptWorkDeadlineRejectsUnqualifiedOrStaleCounts(t *testing.T) {
	s, model, hash := nativeMediaAccountingServer(t)
	t.Cleanup(s.Close)
	fallback := s.FirstContentDeadline(model, 3606)
	for _, tc := range []struct {
		name string
		edit func(*protocol.PromptWork)
	}{
		{"heuristic", func(w *protocol.PromptWork) { w.Source = protocol.PromptWorkHeuristic }},
		{"version", func(w *protocol.PromptWork) { w.Version++ }},
		{"artifact", func(w *protocol.PromptWork) { w.ModelArtifactHash = strings.Repeat("e", 64) }},
		{"contract", func(w *protocol.PromptWork) { w.PromptContractID = strings.Repeat("e", 64) }},
		{"zero", func(w *protocol.PromptWork) { w.PromptTokens = 0 }},
		{"negative", func(w *protocol.PromptWork) { w.PromptTokens = -1 }},
		{"bound", func(w *protocol.PromptWork) { w.UpperBoundTokens = protocol.MaxPromptWorkTokens + 1 }},
		{"uncalibrated", func(w *protocol.PromptWork) { w.Source = protocol.PromptWorkCalibrated }},
		{"unequal_exact", func(w *protocol.PromptWork) { w.UpperBoundTokens++ }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			work := deadlineFixtureWork(t, s, model, 5779)
			tc.edit(work)
			if got := s.promptWorkDeadline(model, model, fallback, work); got != fallback {
				t.Fatalf("unqualified work changed fallback: %v", got)
			}
		})
	}
	work := deadlineFixtureWork(t, s, model, 5779)
	if s.promptWorkDeadline(model, "different-build", fallback, work) != fallback || s.promptWorkDeadline(model, model, fallback, nil) != fallback {
		t.Fatal("absent/different model evidence changed deadline")
	}
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, WeightHash: strings.Repeat("f", 64)}})
	if s.promptWorkDeadline(model, model, fallback, work) != fallback {
		t.Fatal("catalog replacement reused stale provisioned artifact")
	}
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, WeightHash: hash}})
	if s.promptWorkDeadline(model, model, fallback, work) != s.FirstContentDeadline(model, 5779) {
		t.Fatal("current identity did not restore qualified budgeting")
	}
}

func TestPromptWorkDeadlinePreflightAndWriterSpendSameIngressClock(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	t.Cleanup(s.Close)
	received := time.Now().Add(-2 * time.Second)
	work := deadlineFixtureWork(t, s, model, 5779)
	params := inferenceAdmissionParams{receivedAt: received, deadline: s.FirstContentDeadline(model, 3606),
		estimatedPromptTokens: 3606, requestedMaxTokens: 32,
		promptWorkForModel: func(string) *protocol.PromptWork { return work },
		deadlineForWork:    s.promptWorkDeadlineForRequest(context.Background(), received, model, s.FirstContentDeadline(model, 3606))}
	pr := params.firstContentRequest(model, registry.RequestTraits{})
	want := received.Add(14779 * time.Millisecond)
	if pr.FirstContentDeadline != want || pr.EstimatedPromptTokens != 3606 || pr.RequestedMaxTokens != 32 {
		t.Fatalf("budget/physical inputs: %+v want cutoff%v", pr, want)
	}
	if pr.FirstContentDeadlineForIdentity("", "") != received.Add(params.deadline) {
		t.Fatal("isolated preflight lost original fallback policy")
	}
	builder := providerInferenceFrameBuilder("fixture", "key", "ciphertext", pr)
	encoded, err := builder(received.Add(4 * time.Second))
	if err != nil {
		t.Fatal(err)
	}
	var frame protocol.InferenceRequestMessage
	if err := json.Unmarshal(encoded, &frame); err != nil {
		t.Fatal(err)
	}
	if frame.FirstContentBudgetMS != 10779 || frame.PromptWork.PromptTokens != 5779 {
		t.Fatal("writer restarted clock or lost exact count", frame)
	}
	if _, err := builder(want); err == nil {
		t.Fatal("expired qualified clock dispatched")
	}
}

func TestPromptWorkDeadlinePreservesEarlierContextCutoff(t *testing.T) {
	received := time.Now()
	ctx, cancel := context.WithDeadline(context.Background(), received.Add(3*time.Second))
	defer cancel()
	if got := firstContentDurationWithinContext(ctx, received, 14*time.Second); got != 3*time.Second {
		t.Fatal("caller cutoff was extended", got)
	}
	if got := firstContentDurationWithinContext(ctx, received, time.Second); got != time.Second {
		t.Fatal("earlier SLA was extended", got)
	}
	if got := firstContentDurationWithinContext(ctx, received, 0); got != 0 {
		t.Fatal("context cutoff enabled exempt SLA")
	}
	expired, cancelExpired := context.WithDeadline(context.Background(), received.Add(-time.Second))
	defer cancelExpired()
	if got := firstContentDurationWithinContext(expired, received, 14*time.Second); got != time.Nanosecond {
		t.Fatal("expired cutoff became exempt", got)
	}
}

func TestPromptWorkDeadlineConcurrentMemoCannotBorrowBodyVariant(t *testing.T) {
	s, model, _ := nativeMediaAccountingServer(t)
	t.Cleanup(s.Close)
	var memo promptwork.Memo
	received := time.Now()
	fallback := s.FirstContentDeadline(model, 3606)
	deadline := s.promptWorkDeadlineForRequest(context.Background(), received, model, fallback)
	work := deadlineFixtureWork(t, s, model, 5779)
	var wg sync.WaitGroup
	for i := range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			count := 5779
			if i%2 == 0 {
				count = 1200
			}
			body := []byte(strings.Repeat("x", count))
			for range 20 {
				memo.Plan(model, body, func() promptwork.Result {
					copy := *work
					copy.PromptTokens, copy.UpperBoundTokens = count, count
					return promptwork.Result{Work: &copy}
				})
				cached := memo.Lookup(model, body)
				if cached != nil && cached.PromptTokens != count {
					t.Error("concurrent retry borrowed another body variant's count")
					return
				}
				want := fallback
				if cached != nil {
					want = s.FirstContentDeadline(model, count)
				}
				if got := deadline(model, cached); got != want {
					t.Errorf("body%d deadline%v want%v", count, got, want)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func TestPromptWorkDeadlineAliasFallbackUsesCandidateCutoff(t *testing.T) {
	s, _ := testServer(t)
	t.Cleanup(s.Close)
	const desired, previous, alias = "deadline-desired", "deadline-previous", "deadline-alias"
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: desired, SizeGB: 1, MinRAMGB: 24}, {ID: previous, SizeGB: 1, MinRAMGB: 24}})
	s.registry.SetModelAliases(map[string]registry.AliasTarget{alias: {Desired: desired, Previous: previous}})
	provider := registerBuildsProvider(s, "deadline-previous-provider", previous)
	provider.Mu().Lock()
	provider.DecodeTPS, provider.PrefillTPS = 100, 400
	provider.Mu().Unlock()
	// Above500TPS both legacy reports clamp to the same rate, leaving decode
	// recency unknown. Keep distinct accepted measurements for this TTFT gate.
	reportMeasuredFirstContentEvidence(t, s.registry, provider.ID, previous, 400, 100)
	for _, duration := range []time.Duration{14 * time.Second, 500 * time.Millisecond} {
		parsed := map[string]any{"model": desired}
		query := func(model string) *registry.PendingRequest {
			return inferenceAdmissionParams{receivedAt: time.Now().Add(-time.Millisecond), deadline: duration,
				estimatedPromptTokens: 4000, requestedMaxTokens: 32}.firstContentRequest(model, registry.RequestTraits{})
		}
		_, _, _, _, best, measured, switched := s.maybeFallbackAlias(parsed, aliasFallbackTTFT, alias, desired, 4000, 32,
			300*time.Millisecond, registry.RequestTraits{}, false, nil, query)
		if !measured || best < 10*time.Second || switched != (duration == 14*time.Second) {
			t.Fatalf("candidate duration%v best%v measured%t switched%t", duration, best, measured, switched)
		}
	}
}
