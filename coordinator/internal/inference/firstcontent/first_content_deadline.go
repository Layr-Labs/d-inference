package firstcontent

import (
	"time"
)

func FirstContentDeadlineAt(receivedAt time.Time, deadline time.Duration) time.Time {
	if receivedAt.IsZero() || deadline <= 0 {
		return time.Time{}
	}
	return receivedAt.Add(deadline)
}
