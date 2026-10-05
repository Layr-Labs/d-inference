package memory

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) StoreLogReport(accountID string, logData []byte) (int64, error) {
	const maxSize = 10 << 20 // 10 MB
	if len(logData) > maxSize {
		logData = logData[:maxSize]
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.logReportSeq++
	cp := make([]byte, len(logData))
	copy(cp, logData)
	s.history.LogReports = append(s.history.LogReports, store.LogReport{
		ID:           s.logReportSeq,
		AccountID:    accountID,
		LogSizeBytes: int64(len(cp)),
		LogData:      cp,
		CreatedAt:    time.Now(),
	})
	return s.logReportSeq, nil
}

func (s *MemoryStore) GetLogReport(id int64) (*store.LogReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for i := range s.history.LogReports {
		if s.history.LogReports[i].ID == id {
			r := s.history.LogReports[i]
			cp := store.LogReport{
				ID:           r.ID,
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
