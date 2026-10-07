package service

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) machineID() string {
	if x.inventory == nil {
		return ""
	}
	return x.inventory.Identity().ID
}
func (x *Session) keyOwnerMatches(ctx context.Context, key *store.AppAttestShadowKey) bool {
	if key.Owner == x.owner {
		return true
	}
	// A claimed key ID never assigns identity. Same-account reuse must first
	// prove custody through a fresh encrypted assertion. Only after its durable
	// acceptance does inventory attach the credential alias to this session.
	if x.account != "" && key.AccountID == x.account {
		return true
	}
	if x.account == "" || key.AccountID != x.account || key.MachineID == "" || x.machineID() == "" {
		return false
	}
	st, ok := store.As[store.MachineIdentityLookupStore](x.s.store)
	if !ok {
		return false
	}
	canonical, err := st.CanonicalMachineID(ctx, key.MachineID)
	current, currentErr := st.CanonicalMachineID(ctx, x.machineID())
	return err == nil && currentErr == nil && canonical != "" && canonical == current
}
