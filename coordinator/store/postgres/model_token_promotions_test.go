package postgres

import "time"

func promotionClaimEnd(at time.Time) *time.Time { return &at }
