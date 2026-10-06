package shared

import (
	"encoding/json"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func ValidateAutopilotRecord(r store.AutopilotRecord) error {
	if r.CommandID == "" || len(r.CommandID) > 64 || r.At.IsZero() || len(r.ProviderID) > 128 || len(r.Load) > 256 || len(r.Before) > 32 || len(r.After) > 32 || len(r.Unload) > 32 {
		return fmt.Errorf("invalid autopilot record")
	}
	if len(r.Shape) > 64 {
		return fmt.Errorf("invalid shape")
	}
	switch r.Reason {
	case "", "demand", "bootstrap", "protected_floor", "idle_surplus":
	default:
		return fmt.Errorf("invalid reason")
	}
	switch r.Phase {
	case "proposed", "reserved", "started", "succeeded", "failed", "uncertain":
	default:
		return fmt.Errorf("invalid autopilot phase")
	}
	for _, set := range [][]string{r.Before, r.After, r.Unload} {
		for _, id := range set {
			if len(id) > 256 {
				return fmt.Errorf("invalid model ID")
			}
		}
	}
	_, err := json.Marshal(r)
	return err
}
