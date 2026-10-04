package shared

import "github.com/eigeninference/d-inference/coordinator/store"

func AppAttestMachineAlias(account, key string) store.MachineAlias {
	return (store.MachineObservation{AccountID: account, VerifiedAppAttestKey: key}).Aliases()[0]
}
