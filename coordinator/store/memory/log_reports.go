package memory

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) StoreLogReport(accountID string, logData []byte) (int64, error) {
	const maxSize = 10 << 20 // 10 MB
	if len(logData) > maxSize {
		logData = logData[:maxSize]
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.logReportSeq++
	cp := make([]byte, len(logData))
	copy(cp, logData)
	s.logReports = append(s.logReports, contracts.LogReport{
		ID:           s.logReportSeq,
		AccountID:    accountID,
		LogSizeBytes: int64(len(cp)),
		LogData:      cp,
		CreatedAt:    time.Now(),
	})
	return s.logReportSeq, nil
}

func (s *Store) GetLogReport(id int64) (*contracts.LogReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for i := range s.logReports {
		if s.logReports[i].ID == id {
			r := s.logReports[i]
			cp := contracts.LogReport{
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
