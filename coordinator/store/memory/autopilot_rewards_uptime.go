package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/rewardpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

// All bound sessions use the canonical key before the interval union. Key
// rotation, reconnects and overlapping coordinators cannot duplicate uptime.
func (s *MemoryStore) autopilotRewardUptimeLocked(machine autopilotRewardMachine, day time.Time) (bool, error) {
	var sessions []store.ProviderSession
	for _, session := range s.history.ProviderSessions {
		if machine.sessions[session.SessionID] && session.AccountID == machine.accountID {
			session.ProviderKey = machine.id
			sessions = append(sessions, session)
		}
	}
	end := day.AddDate(0, 0, 1)
	if rewardpolicy.UptimeByProviderKey(sessions, day, end, 90*time.Second)[machine.id] >= 0.90 {
		return true, nil
	}
	// Missing intervals cannot lower a proven >=90% union, but they cannot
	// establish a permanent low-uptime result either. Preserve the pending day.
	for session := range machine.sessions {
		if missing, ok := s.history.ProviderUptimePruned[session]; ok && missing.Start.Before(end) && (missing.End.IsZero() || missing.End.After(day)) {
			return false, earningsfloor.ErrHistory
		}
	}
	return false, nil
}
