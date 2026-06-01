package store

import (
	"fmt"
	"time"
)

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
