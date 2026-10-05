package observation_test

import (
	"testing"
	"time"

	outcomes "github.com/eigeninference/d-inference/coordinator/internal/observation/outcomes"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRequestOutcomeClassificationAndMappings(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name       string
		r          store.RequestOutcomeRecord
		want, code string
	}{
		{"recovered deadline", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", ResponseTerminal: "completed", EgressCompleted: true}, "completed", ""},
		{"departure after provider completion", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", ResponseTerminal: "completed", EgressCompleted: true, ClientDeparted: true}, "client_departure", ""},
		{"precontent cancellation with planned429", store.RequestOutcomeRecord{HTTPStatus: 429, ClientDeparted: true, RawStage: "dispatch", RawReason: "first_chunk_timeout"}, "client_departure", ""},
		{"nonstream failure before body", store.RequestOutcomeRecord{HTTPStatus: 502, ProviderContentObserved: true, ProviderOutcome: "error"}, "rejected", "ext_unknown"},
		{"stream incomplete", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderContentObserved: true, ContentWriteCompleted: true}, "interrupted_response", ""},
		{"write failure", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", ClientWriteError: true}, "interrupted_response", ""},
		{"zero token complete", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", ResponseTerminal: "completed", EgressCompleted: true}, "completed", ""},
		{"preamble only", store.RequestOutcomeRecord{HTTPStatus: 200, EgressCompleted: true}, "unknown", ""},
		{"final timeout", store.RequestOutcomeRecord{HTTPStatus: 429, RawStage: "dispatch", RawReason: "first_chunk_timeout"}, "rejected", "ext_first_content_timeout"},
		{"deadline exhaustion", store.RequestOutcomeRecord{HTTPStatus: 429, RawStage: "dispatch", RawReason: "deadline_unreachable"}, "rejected", "ext_coordinator_exhausted"},
		{"typed provider timeout", store.RequestOutcomeRecord{HTTPStatus: 504, RawStage: "dispatch", RawReason: "dispatch_exhausted"}, "rejected", "ext_legacy:dispatch_exhausted"},
		{"queue timeout", store.RequestOutcomeRecord{HTTPStatus: 429, RawStage: "queue", RawReason: "queue_timeout"}, "rejected", "ext_legacy:queue_timeout"},
		{"conflicting evidence", store.RequestOutcomeRecord{HTTPStatus: 200, EgressCompleted: true, ProviderOutcome: "completed", EvidenceConflict: true}, "unknown", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.r.HandlerFinishedAt = &now
			outcomes.Classify(&tc.r)
			if tc.r.Termination != tc.want || tc.r.NormalizedCode != tc.code {
				t.Fatalf("got %+v", tc.r)
			}
		})
	}
	if got := outcomes.NormalizedAttempt("deadline_unreachable"); got != "int_provider_deadline_rejected" {
		t.Fatal(got)
	}
}
