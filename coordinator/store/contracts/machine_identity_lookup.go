package contracts

import (
	"context"
)

type MachineIdentityLookupStore interface {
	CanonicalMachineID(context.Context, string) (string, error)
}
