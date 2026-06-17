package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"
)

// --- Releases ---

func releaseKey(version, platform string) string {
	return version + ":" + platform
}

func (s *MemoryStore) SetRelease(release *Release) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if release.Version == "" || release.Platform == "" {
		return errors.New("version and platform are required")
	}
	r := *release
	if r.CreatedAt.IsZero() {
		r.CreatedAt = time.Now()
	}
	r.Active = true
	s.releases[releaseKey(r.Version, r.Platform)] = &r
	return nil
}

func (s *MemoryStore) ListReleases() []Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	releases := make([]Release, 0, len(s.releases))
	for _, r := range s.releases {
		releases = append(releases, *r)
	}
	sort.Slice(releases, func(i, j int) bool {
		return releases[i].CreatedAt.After(releases[j].CreatedAt)
	})
	return releases
}

func (s *MemoryStore) GetLatestRelease(platform string) *Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var latest *Release
	for _, r := range s.releases {
		if r.Platform != platform || !r.Active {
			continue
		}
		if latest == nil ||
			releaseVersionGreater(r.Version, latest.Version) ||
			(r.Version == latest.Version && r.CreatedAt.After(latest.CreatedAt)) {
			latest = r
		}
	}
	if latest == nil {
		return nil
	}
	copy := *latest
	return &copy
}

func (s *MemoryStore) DeleteRelease(version, platform string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := releaseKey(version, platform)
	r, ok := s.releases[key]
	if !ok {
		return fmt.Errorf("release %s/%s not found", version, platform)
	}
	r.Active = false
	return nil
}

// --- Provider Fleet Persistence ---

func (s *MemoryStore) UpsertProvider(_ context.Context, p ProviderRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update serial index
	if p.SerialNumber != "" {
		// Remove old serial mapping if exists
		if old, ok := s.providerRecords[p.ID]; ok && old.SerialNumber != "" && old.SerialNumber != p.SerialNumber {
			delete(s.serialToProviderID, old.SerialNumber)
		}
		s.serialToProviderID[p.SerialNumber] = p.ID
	}

	cp := p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	s.providerRecords[p.ID] = &cp
	return nil
}

func (s *MemoryStore) GetProviderRecord(_ context.Context, id string) (*ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return nil, fmt.Errorf("provider %q not found", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) GetProviderBySerial(_ context.Context, serial string) (*ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	id, ok := s.serialToProviderID[serial]
	if !ok {
		return nil, fmt.Errorf("provider with serial %q not found", serial)
	}
	p, ok := s.providerRecords[id]
	if !ok {
		return nil, fmt.Errorf("provider %q not found (stale serial index)", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) ListProviderRecords(_ context.Context) ([]ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0, len(s.providerRecords))
	for _, p := range s.providerRecords {
		cp := *p
		if p.Location != nil {
			loc := *p.Location
			cp.Location = &loc
		}
		records = append(records, cp)
	}
	return records, nil
}

func (s *MemoryStore) ListProvidersByAccount(_ context.Context, accountID string) ([]ProviderRecord, error) {
	if accountID == "" {
		return []ProviderRecord{}, nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0)
	for _, p := range s.providerRecords {
		if p.AccountID == accountID {
			cp := *p
			if p.Location != nil {
				loc := *p.Location
				cp.Location = &loc
			}
			records = append(records, cp)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i].LastSeen.After(records[j].LastSeen)
	})
	return records, nil
}

func (s *MemoryStore) DeleteProvidersBySerial(_ context.Context, ownerAccountID, serialOrID string) (int, error) {
	if ownerAccountID == "" || serialOrID == "" {
		return 0, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	var matched []string
	for id, rec := range s.providerRecords {
		if rec.AccountID != ownerAccountID {
			continue
		}
		if (rec.SerialNumber == serialOrID && rec.SerialNumber != "") || rec.ID == serialOrID {
			matched = append(matched, id)
		}
	}
	for _, id := range matched {
		rec := s.providerRecords[id]
		if rec.SerialNumber != "" && s.serialToProviderID[rec.SerialNumber] == id {
			delete(s.serialToProviderID, rec.SerialNumber)
		}
		delete(s.providerRecords, id)
		delete(s.reputationRecords, id)
	}
	return len(matched), nil
}

func (s *MemoryStore) UpdateProviderLastSeen(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastSeen = time.Now()
	return nil
}

func (s *MemoryStore) UpdateProviderTrust(_ context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.TrustLevel = trustLevel
	p.Attested = attested
	p.AttestationResult = attestationResult
	return nil
}

func (s *MemoryStore) UpdateProviderChallenge(_ context.Context, id string, lastVerified time.Time, failedCount int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastChallengeVerified = &lastVerified
	p.FailedChallenges = failedCount
	return nil
}

func (s *MemoryStore) UpdateProviderRuntime(_ context.Context, id string, verified bool, pythonHash, runtimeHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.RuntimeVerified = verified
	p.PythonHash = pythonHash
	p.RuntimeHash = runtimeHash
	return nil
}

// --- Provider Reputation Persistence ---

func (s *MemoryStore) UpsertReputation(_ context.Context, providerID string, rep ReputationRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := rep
	s.reputationRecords[providerID] = &cp
	return nil
}

func (s *MemoryStore) GetReputation(_ context.Context, providerID string) (*ReputationRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rep, ok := s.reputationRecords[providerID]
	if !ok {
		return nil, fmt.Errorf("reputation for provider %q not found", providerID)
	}
	cp := *rep
	return &cp, nil
}

// --- Provider Log Reports ---

func (s *MemoryStore) StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error {
	const maxSize = 10 << 20 // 10 MB
	if len(logData) > maxSize {
		logData = logData[:maxSize]
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.logReportSeq++
	cp := make([]byte, len(logData))
	copy(cp, logData)
	s.logReports = append(s.logReports, LogReport{
		ID:           s.logReportSeq,
		SerialNumber: serialNumber,
		ProviderID:   providerID,
		AccountID:    accountID,
		LogSizeBytes: int64(len(cp)),
		LogData:      cp,
		CreatedAt:    time.Now(),
	})
	return nil
}

func (s *MemoryStore) GetLogReports(serialNumber string, limit int) ([]LogReport, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	var reports []LogReport
	for i := len(s.logReports) - 1; i >= 0; i-- {
		r := s.logReports[i]
		if r.SerialNumber != serialNumber {
			continue
		}
		// Return without log data for list queries.
		reports = append(reports, LogReport{
			ID:           r.ID,
			SerialNumber: r.SerialNumber,
			ProviderID:   r.ProviderID,
			AccountID:    r.AccountID,
			LogSizeBytes: r.LogSizeBytes,
			CreatedAt:    r.CreatedAt,
		})
		if len(reports) >= limit {
			break
		}
	}
	if reports == nil {
		return []LogReport{}, nil
	}
	return reports, nil
}

func (s *MemoryStore) GetLogReport(id int64) (*LogReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for i := range s.logReports {
		if s.logReports[i].ID == id {
			r := s.logReports[i]
			cp := LogReport{
				ID:           r.ID,
				SerialNumber: r.SerialNumber,
				ProviderID:   r.ProviderID,
				AccountID:    r.AccountID,
				LogSizeBytes: r.LogSizeBytes,
				CreatedAt:    r.CreatedAt,
				LogData:      make([]byte, len(r.LogData)),
			}
			copy(cp.LogData, r.LogData)
			return &cp, nil
		}
	}
	return nil, fmt.Errorf("log report %d not found", id)
}

// OpenProviderSession records the start of a provider connection. Idempotent
// (mirrors the postgres ON CONFLICT DO NOTHING): if a row for sessionID already
// exists — duplicate register, or open racing behind a close — it does nothing.
func (s *MemoryStore) OpenProviderSession(_ context.Context, sessionID, serial, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.providerSessions {
		if s.providerSessions[i].SessionID == sessionID {
			return nil
		}
	}
	now := time.Now()
	s.providerSessionSeq++
	s.providerSessions = append(s.providerSessions, ProviderSession{
		ID:           s.providerSessionSeq,
		SessionID:    sessionID,
		SerialNumber: serial,
		AccountID:    accountID,
		ConnectedAt:  now,
		LastSeen:     now,
	})
	return nil
}

// TouchProviderSession updates the open session's last_seen and backfills
// serial/account if they were unknown at open time.
func (s *MemoryStore) TouchProviderSession(_ context.Context, sessionID, serial, accountID string, lastSeen time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.providerSessions {
		ps := &s.providerSessions[i]
		if ps.SessionID == sessionID && ps.DisconnectedAt == nil {
			ps.LastSeen = lastSeen
			if ps.SerialNumber == "" {
				ps.SerialNumber = serial
			}
			if ps.AccountID == "" {
				ps.AccountID = accountID
			}
			// At most one open row per sessionID (OpenProviderSession
			// guarantees it), so stop scanning once matched.
			return nil
		}
	}
	return nil
}

// CloseProviderSession marks the session for sessionID as ended. Upsert
// semantics (mirrors postgres): closes an open row; leaves an already-closed row
// untouched; and if the row is missing (close raced ahead of open) inserts an
// already-closed row so no permanently-open session can be orphaned.
func (s *MemoryStore) CloseProviderSession(_ context.Context, sessionID, reason string, when time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.providerSessions {
		ps := &s.providerSessions[i]
		if ps.SessionID == sessionID {
			if ps.DisconnectedAt == nil {
				t := when
				ps.DisconnectedAt = &t
				ps.DisconnectReason = reason
			}
			return nil
		}
	}
	t := when
	s.providerSessionSeq++
	s.providerSessions = append(s.providerSessions, ProviderSession{
		ID:               s.providerSessionSeq,
		SessionID:        sessionID,
		ConnectedAt:      when,
		LastSeen:         when,
		DisconnectedAt:   &t,
		DisconnectReason: reason,
	})
	return nil
}

// CloseOpenProviderSessions closes any sessions still open, setting
// disconnected_at to the last heartbeat (startup reconcile).
func (s *MemoryStore) CloseOpenProviderSessions(_ context.Context, staleBefore time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for i := range s.providerSessions {
		ps := &s.providerSessions[i]
		// Only close genuinely-orphaned sessions (last heartbeat older than the
		// staleness fence); a session still touched by another live instance
		// during a blue-green deploy stays fresh and is left open.
		if ps.DisconnectedAt == nil && ps.LastSeen.Before(staleBefore) {
			t := ps.LastSeen
			ps.DisconnectedAt = &t
			ps.DisconnectReason = "coordinator_restart"
			n++
		}
	}
	return n, nil
}

// sha256Hex returns the hex-encoded SHA-256 digest of s.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
