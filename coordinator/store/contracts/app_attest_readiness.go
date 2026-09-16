package contracts

import (
	"context"
)

type AppAttestReadiness struct {
	Revoked bool
	Receipt *AppAttestReceipt
}

type AppAttestReadinessStore interface {
	GetAppAttestReadiness(context.Context, string) (AppAttestReadiness, error)
	RevokeAppAttestKey(context.Context, string, string, string) (bool, error)
}
