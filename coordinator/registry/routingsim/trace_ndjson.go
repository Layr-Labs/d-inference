package routingsim

// Sampling caveat: request_profiles keeps every non-success / slow / retried
// / backup / client-gone request but only EIGENINFERENCE_PROFILE_SAMPLE_RATE
// of plain successes (default 10 %). A trace loaded from a default-rate export
// is therefore biased toward anomalous requests; export with the rate set to
// 1.0 (or weight arrivals by the inverse rate) before drawing rate conclusions.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// LoadProfilesNDJSON reads a request_profiles export — the admin
// GET /v1/admin/profiles/export format: one store.RequestProfileRecord JSON
// object per line — and turns it into a replay trace.
//
// Row selection: only WINNING attempts become arrivals (a coord_request_id
// with a losing backup attempt contributes exactly one arrival), and rows
// whose estimated_prompt_tokens is zero are skipped — they predate the
// request-shape columns or never reached the router, so there is no shape to
// replay. Arrivals are sorted by received_at (stable, so rows sharing a
// timestamp keep file order).
//
// Blank lines are ignored. A malformed line fails the whole load with an error
// naming the 1-based line number; a partial trace is never returned.
func LoadProfilesNDJSON(r io.Reader) ([]Arrival, error) {
	if r == nil {
		return nil, errors.New("routingsim: nil profiles reader")
	}
	var arrivals []Arrival
	err := forEachNDJSONLine(r, func(lineNo int, line []byte) error {
		var rec store.RequestProfileRecord
		if err := json.Unmarshal(line, &rec); err != nil {
			return fmt.Errorf("routingsim: profiles ndjson line %d: %w", lineNo, err)
		}
		if !rec.Winning || rec.EstimatedPromptTokens <= 0 {
			return nil
		}
		arrivals = append(arrivals, arrivalFromProfile(&rec))
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.SliceStable(arrivals, func(i, j int) bool {
		return arrivals[i].ArrivedAt.Before(arrivals[j].ArrivedAt)
	})
	return arrivals, nil
}

// arrivalFromProfile maps one winning profile row onto an Arrival.
func arrivalFromProfile(rec *store.RequestProfileRecord) Arrival {
	a := Arrival{
		Model:            rec.Model,
		PromptTokens:     rec.EstimatedPromptTokens,
		MaxTokens:        rec.RequestedMaxTokens,
		ArrivedAt:        rec.ReceivedAt,
		RequiresVision:   rec.RequiresVision,
		HasTools:         rec.HasTools,
		ChosenProviderID: rec.ProviderID,
		CoordRequestID:   rec.CoordRequestID,
		Attempt:          rec.Attempt,
	}
	// Provider-side TTFT proxy (see Arrival.ActualTTFTMs). Both stamps must be
	// present; a negative span (clock anomaly, already flagged by
	// timing_anomaly at the source) is reported as unknown rather than as a
	// nonsense negative latency.
	if rec.FirstContentIngressUS != nil && rec.WriteDoneUS != nil {
		if span := *rec.FirstContentIngressUS - *rec.WriteDoneUS; span >= 0 {
			a.ActualTTFTMs = float64(span) / 1000
		}
	}
	return a
}

// forEachNDJSONLine calls fn for every non-blank line of r with its 1-based
// line number. Lines are read with bufio.Reader so a row carrying a large
// JSONB document (provider_profile, candidates) is never truncated by a
// scanner buffer cap. The first error from fn or the reader is returned.
func forEachNDJSONLine(r io.Reader, fn func(lineNo int, line []byte) error) error {
	br := bufio.NewReader(r)
	for lineNo := 1; ; lineNo++ {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 {
				if ferr := fn(lineNo, trimmed); ferr != nil {
					return ferr
				}
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("routingsim: ndjson line %d: %w", lineNo, err)
		}
	}
}
