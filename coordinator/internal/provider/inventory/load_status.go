package inventory

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func ValidLoadModelStatus(status string) bool {
	switch status {
	case protocol.LoadModelStatusStarted,
		protocol.LoadModelStatusSucceeded,
		protocol.LoadModelStatusFailed:
		return true
	default:
		return false
	}
}
