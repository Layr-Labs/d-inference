// Package rejection records inbound inference rejections and writes terminals
// before the response has committed any content.
package rejection

import (
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Servability distinguishes an authoritative caller computation from a scan
// deliberately skipped while shedding load.
type Servability struct {
	Computed bool
	Skip     bool
}

type Dependencies struct {
	Store           store.Store
	Registry        *registry.Registry
	Observation     *observation.Owner
	Metrics         *infermetrics.Reporter
	AnnotateOutcome func(*http.Request, *store.RejectionRecord)
	AnnotateDemand  func(*http.Request, *store.RejectionRecord)
	RecordOutcome   func(model, class string)
}

type Recorder struct {
	deps Dependencies
}

func New(d Dependencies) *Recorder { return &Recorder{deps: d} }

// Record owns the supplied ledger record after return. Persistence and any
// missing counterfactual scan run on the existing observation telemetry worker.
func (s *Recorder) Record(r *http.Request, rec *store.RejectionRecord, decision Servability) {
	if s.deps.AnnotateOutcome != nil {
		s.deps.AnnotateOutcome(r, rec)
	}
	if s.deps.AnnotateDemand != nil {
		s.deps.AnnotateDemand(r, rec)
	}
	if s.deps.Store == nil {
		return
	}

	rec.CreatedAt = time.Now()
	if r != nil {
		rec.RequestID = observation.CoordRequestIDFromContext(r.Context())
		rec.Endpoint = r.URL.Path
		rec.ClientClass = clientClassFromUserAgent(r.UserAgent())
		if rec.RequestBodyBytes == 0 && r.ContentLength > 0 {
			rec.RequestBodyBytes = int(r.ContentLength)
		}
	}

	// Dispatch exhaustion is counted by the dispatch tail. All pre-dispatch
	// rejections contribute exactly one outcome, with unknown KV attribution.
	if rec.Stage != "dispatch" {
		model := rec.ResolvedModel
		if model == "" {
			model = rec.RequestedModel
		}
		class := infermetrics.ORUptimeClassForRejection(rec.HTTPStatus)
		s.deps.RecordOutcome(model, class)
		// The raw requested name is client controlled and cannot mint OR-view tags.
		s.deps.Metrics.RecordORView(rec.ResolvedModel, class)
	}

	computeServability := !decision.Skip && !decision.Computed && rec.ResolvedModel != "" && s.deps.Registry != nil
	s.deps.Observation.SubmitTelemetry("recordRejection", func() {
		if computeServability {
			traits := registry.RequestTraits{HasTools: rec.HasTools}
			cc, capRej, tooLarge, bestTTFT, hasTTFT := s.deps.Registry.QuickCapacityCheckWithTTFTForRequest(
				rec.ResolvedModel, rec.EstimatedPromptTokens, rec.RequestedMaxTokens, traits, rec.RequiresVision,
			)
			rec.CandidateCount = cc
			rec.CapacityRejections = capRej
			rec.ModelTooLargeRejections = tooLarge
			if hasTTFT {
				rec.BestTTFTMs = float64(bestTTFT.Milliseconds())
			}
		}
		if decision.Computed || computeServability {
			couldHaveServed := rec.CandidateCount > 0
			rec.CouldHaveServed = &couldHaveServed
		}
		_ = s.deps.Store.RecordRejection(rec)
	})
}

// clientClassFromUserAgent stores a coarse client bucket, never a raw header.
func clientClassFromUserAgent(ua string) string {
	if ua == "" {
		return "unknown"
	}
	if len(ua) > 256 {
		ua = ua[:256]
	}
	lc := strings.ToLower(ua)
	switch {
	case strings.Contains(lc, "openrouter"):
		return "openrouter"
	case strings.Contains(lc, "darkbloom"):
		return "darkbloom"
	case strings.Contains(lc, "python"), strings.Contains(lc, "openai"):
		return "openai-sdk"
	case strings.Contains(lc, "node"), strings.Contains(lc, "axios"), strings.Contains(lc, "fetch"):
		return "js-sdk"
	case strings.Contains(lc, "curl"):
		return "curl"
	default:
		return "direct"
	}
}
