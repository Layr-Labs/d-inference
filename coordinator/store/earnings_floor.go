package store

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

// AutopilotRewardsStore serializes enrollment and daily credits with canonical
// inventory merges. A daily receipt, pool spending, withdrawable credit and
// non-inference earning commit together. No method changes ordinary base rewards.
type AutopilotRewardsStore interface {
	ObserveAutopilotConsent(context.Context, earningsfloor.Consent) (earningsfloor.Enrollment, error)
	RestoreAutopilotBaseline(context.Context, earningsfloor.Baseline) (earningsfloor.Enrollment, error)
	AutopilotRewardEnrollments(context.Context, string, int) ([]earningsfloor.Enrollment, error)
	AutopilotRewardPool(context.Context) (earningsfloor.Pool, error)
	SetAutopilotRewardPoolCap(context.Context, int64) (earningsfloor.Pool, error)
	SettleAutopilotRewardDay(context.Context, string, time.Time) (earningsfloor.Settlement, error)
}
