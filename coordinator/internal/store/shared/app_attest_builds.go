package shared

import (
	"errors"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func ValidateBuildRevocation(binary, actor, reason string) error {
	if !store.ValidBuildDigest(binary, 64) || actor == "" || len(actor) > 256 || strings.TrimSpace(reason) == "" || len(reason) > 4096 {
		return errors.New("revocation requires binary SHA-256, operator identity and reason")
	}
	return nil
}
