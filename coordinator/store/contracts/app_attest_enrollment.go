package contracts

import (
	"context"
	"time"
)

type AppAttestEnrollment struct {
	ProtocolVersion int       `json:"protocol_version,omitempty"`
	ID              string    `json:"id"`
	Owner           string    `json:"owner"`
	KeyID           string    `json:"key_id"`
	CreatedAt       time.Time `json:"created_at"`
	Environment     string    `json:"environment"`
	AppID           string    `json:"app_id"`
	Challenge       string    `json:"challenge"`
	PublicKey       string    `json:"public_key"`
	AccountScope    string    `json:"account_scope"`
}

type AppAttestEnrollmentStore interface {
	SaveAppAttestEnrollment(context.Context, AppAttestEnrollment) error
	GetAppAttestEnrollment(context.Context, string) (*AppAttestEnrollment, error)
}
