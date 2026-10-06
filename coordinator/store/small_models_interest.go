package store

import (
	"context"
	"time"
)

// SmallModelsInterest records the latest hardware an account wants notified about.
// Contact details are joined from users at export time, never accepted from clients.
type SmallModelsInterest struct {
	AccountID string    `json:"account_id"`
	MacType   string    `json:"mac_type"`
	Chip      string    `json:"chip"`
	RAMGB     int       `json:"ram_gb"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type SmallModelsInterestContact struct {
	SmallModelsInterest
	Email string `json:"email"`
}

type SmallModelsInterestStore interface {
	UpsertSmallModelsInterest(context.Context, SmallModelsInterest) error
	GetSmallModelsInterest(context.Context, string) (*SmallModelsInterest, error)
	ListSmallModelsInterest(context.Context, string, int) ([]SmallModelsInterestContact, error)
}
