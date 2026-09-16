package contracts

import (
	"context"
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
}
