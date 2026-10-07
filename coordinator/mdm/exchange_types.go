package mdm

import (
	"github.com/eigeninference/d-inference/coordinator/internal/mdm/command"
	"github.com/eigeninference/d-inference/coordinator/internal/mdm/exchange"
)

type SecurityInfoResponse = exchange.SecurityInfoResponse
type DeviceAttestationResponse = exchange.DeviceAttestationResponse

var ErrWaiterAlreadyRegistered = exchange.ErrWaiterAlreadyRegistered
var ErrMutatingCommandBlocked = command.ErrMutatingCommandBlocked
