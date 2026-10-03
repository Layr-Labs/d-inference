package api

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func setPromptDeadlineProviderContract(s *Server, p *failoverProvider, contract string) {
	provider := s.registry.GetProvider(p.registryID)
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	identity := provider.BackendCapacity.Slots[0].PromptWorkIdentity
	if contract == "" {
		provider.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	} else {
		copy := *identity
		copy.PromptContractID = contract
		provider.BackendCapacity.Slots[0].PromptWorkIdentity = &copy
	}
}

func TestPromptWorkDeadlineHTTPUnqualifiedServingContractKeepsFallback(t *testing.T) {
	for _, contract := range []string{"", strings.Repeat("e", 64)} {
		for _, count := range []int{1200, 5779} {
			t.Run(fmt.Sprintf("contract%t/count%d", contract != "", count), func(t *testing.T) {
				_, _, s, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 9 * time.Second})
				t.Cleanup(s.Close)
				f := newPromptDeadlineFixture(t, s)
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				seen := make(chan promptDeadlineDispatch, 1)
				provider := startPromptDeadlineProvider(t, ctx, ts, s, f, seen)
				setPromptDeadlineProviderContract(s, provider, contract)
				input := fmt.Sprintf("fixture_count=%d ", count) + strings.Repeat("x", 16_000)
				status, body, err := postGenericInference(ctx, ts.URL, "/v1/chat/completions", promptDeadlineBody(f.model, "/v1/chat/completions", input, false))
				if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
					t.Fatalf("legacy serving contract HTTP%d err%v body%s", status, err, body)
				}
				dispatch := <-seen
				want := s.FirstContentDeadline(f.model, dispatch.estimate)
				if got := dispatch.deadline.Sub(dispatch.received); got != want {
					t.Fatalf("unqualified serving renderer inherited canonical cutoff: got%v want fallback%v (exact%d, heuristic%d)", got, want, count, dispatch.estimate)
				}
				if dispatch.wireMS > want.Milliseconds() || dispatch.wireMS < want.Milliseconds()-1500 {
					t.Fatalf("wire did not retain original fallback cutoff: %+v", dispatch)
				}
			})
		}
	}
}

func TestPromptWorkDeadlineHTTPMixedContractsDoNotBorrowMatchingPeer(t *testing.T) {
	_, _, s, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	f := newPromptDeadlineFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	matchingSeen, legacySeen := make(chan promptDeadlineDispatch, 1), make(chan promptDeadlineDispatch, 1)
	matching := startPromptDeadlineProvider(t, ctx, ts, s, f, matchingSeen)
	reportMeasuredFirstContentEvidence(t, s.registry, matching.registryID, f.model, 1000, 100)
	legacy := startPromptDeadlineProvider(t, ctx, ts, s, f, legacySeen)
	setPromptDeadlineProviderContract(s, legacy, "")
	input := "fixture_count=1200 " + strings.Repeat("x", 16_000)
	status, body, err := postGenericInference(ctx, ts.URL, "/v1/chat/completions", promptDeadlineBody(f.model, "/v1/chat/completions", input, false))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
		t.Fatalf("mixed renderer fleet HTTP%d err%v body%s", status, err, body)
	}
	if matching.dispatches.Load() != 0 || legacy.dispatches.Load() != 1 {
		t.Fatal("fixture did not select the faster unqualified provider")
	}
	dispatch := <-legacySeen
	if want := s.FirstContentDeadline(f.model, dispatch.estimate); dispatch.deadline.Sub(dispatch.received) != want {
		t.Fatalf("matching fleet peer lent canonical cutoff to selected legacy renderer: %+v want fallback%v", dispatch, want)
	}
}

func TestPromptWorkDeadlineHTTPUnqualifiedFeasiblePreflightIsNotRejected(t *testing.T) {
	_, _, s, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	s.SetTTFTHardReject(true)
	t.Cleanup(s.Close)
	f := newPromptDeadlineFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	seen := make(chan promptDeadlineDispatch, 1)
	provider := startPromptDeadlineProvider(t, ctx, ts, s, f, seen)
	setPromptDeadlineProviderContract(s, provider, "")
	reportMeasuredFirstContentEvidence(t, s.registry, provider.registryID, f.model, 400, 100)
	input := "fixture_count=1200 " + strings.Repeat("x", 16_000)
	status, body, err := postGenericInference(ctx, ts.URL, "/v1/chat/completions", promptDeadlineBody(f.model, "/v1/chat/completions", input, false))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
		t.Fatalf("fallback-feasible legacy request refused by canonical preflight: HTTP%d err%v body%s", status, err, body)
	}
	dispatch := <-seen
	if dispatch.deadline.Sub(dispatch.received) != s.FirstContentDeadline(f.model, dispatch.estimate) {
		t.Fatal("serving preflight and final dispatch did not use fallback")
	}
}
