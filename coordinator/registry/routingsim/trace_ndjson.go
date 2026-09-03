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
// Row selection: one arrival per logical request (coord_request_id) — the
// winning attempt when one exists, otherwise a representative non-winning
// attempt (primary before backup, lowest attempt) so fully-failed requests
// stay in the trace as demand; rows whose estimated_prompt_tokens is zero are
// skipped — they predate the request-shape columns or never reached the
// router, so there is no shape to replay. Arrivals are sorted by received_at
// (stable, so rows sharing a timestamp keep file order).
//
// Blank lines are ignored. A malformed line fails the whole load with an error
// naming the 1-based line number; a partial trace is never returned.
func LoadProfilesNDJSON(r io.Reader) ([]Arrival, error) {
	if r == nil {
		return nil, errors.New("routingsim: nil profiles reader")
	}
	// One arrival per logical request (coord_request_id): the winning row
	// when there is one, otherwise ONE representative non-winning row so a
	// request whose every attempt failed still counts as demand — those are
	// always-recorded and dominate exactly the incident windows a replay is
	// meant to study. Representative = the primary (empty backup_of) with the
	// lowest attempt; a backup row only stands in when no primary row exists.
	type pick struct {
		rec   store.RequestProfileRecord
		order int
	}
	byRequest := map[string]pick{}
	var keys []string
	order := 0
	err := forEachNDJSONLine(r, func(lineNo int, line []byte) error {
		var rec store.RequestProfileRecord
		if err := json.Unmarshal(line, &rec); err != nil {
			return fmt.Errorf("routingsim: profiles ndjson line %d: %w", lineNo, err)
		}
		if rec.EstimatedPromptTokens <= 0 {
			return nil
		}
		key := rec.CoordRequestID
		if key == "" {
			key = rec.RequestID
		}
		cur, seen := byRequest[key]
		if !seen {
			byRequest[key] = pick{rec: rec, order: order}
			keys = append(keys, key)
			order++
			return nil
		}
		if betterArrivalRow(&rec, &cur.rec) {
			byRequest[key] = pick{rec: rec, order: cur.order}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	arrivals := make([]Arrival, 0, len(keys))
	for _, key := range keys {
		rec := byRequest[key].rec
		arrivals = append(arrivals, arrivalFromProfile(&rec))
	}
	sort.SliceStable(arrivals, func(i, j int) bool {
		return arrivals[i].ArrivedAt.Before(arrivals[j].ArrivedAt)
	})
	return arrivals, nil
}

// betterArrivalRow reports whether candidate should replace current as the
// row representing a logical request: winning beats non-winning; among
// non-winning rows a primary beats a backup and a lower attempt beats a
// higher one.
func betterArrivalRow(candidate, current *store.RequestProfileRecord) bool {
	if candidate.Winning != current.Winning {
		return candidate.Winning
	}
	if candidate.Winning {
		return false // keep the first winner seen
	}
	if (candidate.BackupOf == "") != (current.BackupOf == "") {
		return candidate.BackupOf == ""
	}
	return candidate.Attempt < current.Attempt
}

// arrivalFromProfile maps one profile row onto an Arrival. Served is true
// only for a winning row; ActualTTFTMs is left unknown otherwise.
func arrivalFromProfile(rec *store.RequestProfileRecord) Arrival {
	a := Arrival{
		Served:           rec.Winning,
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
	if rec.Winning && rec.FirstContentIngressUS != nil && rec.WriteDoneUS != nil {
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
