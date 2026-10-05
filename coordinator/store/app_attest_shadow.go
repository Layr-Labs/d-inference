package store

import (
	"context"
	"time"
)

// AppAttestShadowStore is observation-only storage, discovered through As so
// CachedStore does not hide it. These records are never provider trust records.
type AppAttestShadowStore interface {
	GetAppAttestShadowKey(context.Context, string) (*AppAttestShadowKey, error)
	InsertAppAttestShadowKey(context.Context, AppAttestShadowKey) (bool, error)
	AdvanceAppAttestShadowCounter(context.Context, string, string, uint32) (bool, error)
}

type AppAttestShadowKey struct {
	MachineID          string  `json:"machine_id,omitempty"`
	AccountID          string  `json:"account_id,omitempty"`
	KeyID              string  `json:"key_id"`
	Owner              string  `json:"owner"`
	PublicKey          []byte  `json:"public_key"`
	Environment        string  `json:"environment"`
	AppID              string  `json:"app_id"`
	BundleVersion      string  `json:"bundle_version"`
	ValidationCategory *uint32 `json:"validation_category,omitempty"`
	Counter            uint32  `json:"counter"`
	// UpdatedAt is the row's insert time or its last accepted counter advance,
	// i.e. the key's last verified assertion. It is never serialized into the
	// evidence JSON and never authorizes anything.
	UpdatedAt time.Time `json:"-"`
}
