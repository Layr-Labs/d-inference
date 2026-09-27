// Package analyticssnapshot validates bounded, versioned public analytics snapshots.
package analyticssnapshot

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const MaxBytes = 8 << 20

// Polling a local file is cheap; the producer refreshes data every five minutes.
const RefreshInterval = 30 * time.Second
const MaxSourceAge = 10 * time.Minute
const MaxResultAge = 15 * time.Minute

var Windows = []string{"24h", "7d", "30d", "all"}
var Metrics = []string{"earnings", "tokens", "jobs"}

type Window struct {
	Leaderboards map[string][]store.LeaderboardRow `json:"leaderboards"`
	Totals       store.NetworkTotalsRow            `json:"totals"`
}

type Snapshot struct {
	Series                map[string]Series `json:"series"`
	SchemaVersion         int               `json:"schema_version"`
	Generation            string            `json:"generation"`
	ReconciliationID      string            `json:"reconciliation_id"`
	SourceComplete        bool              `json:"source_complete"`
	SourceCompleteThrough time.Time         `json:"source_complete_through"`
	AsOf                  time.Time         `json:"as_of"`
	GeneratedAt           time.Time         `json:"generated_at"`
	Windows               map[string]Window `json:"windows"`
}

func (s *Snapshot) Fresh(now time.Time) bool {
	return !s.SourceCompleteThrough.After(now) && !s.AsOf.After(s.SourceCompleteThrough) &&
		!s.GeneratedAt.After(now.Add(time.Minute)) && !s.GeneratedAt.Before(s.SourceCompleteThrough) &&
		now.Sub(s.SourceCompleteThrough) <= MaxSourceAge && now.Sub(s.AsOf) <= MaxSourceAge &&
		now.Sub(s.GeneratedAt) <= MaxResultAge
}

func Decode(r io.Reader, now time.Time) (*Snapshot, error) {
	raw, err := io.ReadAll(io.LimitReader(r, MaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > MaxBytes {
		return nil, errors.New("analytics snapshot exceeds size limit")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var s Snapshot
	if err := dec.Decode(&s); err != nil {
		return nil, fmt.Errorf("analytics snapshot decode: %w", err)
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return nil, errors.New("analytics snapshot has trailing content")
	}
	if s.SchemaVersion != 1 || s.Generation == "" || len(s.Generation) > 128 || s.ReconciliationID == "" || len(s.ReconciliationID) > 256 || !s.SourceComplete || !s.Fresh(now) {
		return nil, errors.New("analytics snapshot is unqualified or stale")
	}
	if err := s.validateRankings(); err != nil {
		return nil, err
	}
	if err := s.validateSeries(); err != nil {
		return nil, err
	}
	return &s, nil
}
