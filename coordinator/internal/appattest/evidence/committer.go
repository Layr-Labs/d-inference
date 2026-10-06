package evidence

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

var ErrUnavailable = errors.New("evidence archive unavailable")

// Committer owns acceptance and gap fencing for a pending durable proof.
type Committer struct {
	archive       store.AppAttestArchiveStore
	integrity     *Integrity
	authorization *authorization.Controller
	provider      *registry.Provider
}

func NewCommitter(archive store.AppAttestArchiveStore, integrity *Integrity, controller *authorization.Controller, provider *registry.Provider) *Committer {
	return &Committer{archive: archive, integrity: integrity, authorization: controller, provider: provider}
}

func (c *Committer) Complete(ctx context.Context, id, action string, decision store.AppAttestDecision) (string, error) {
	if c.archive == nil || id == "" {
		c.integrity.Drop(c.authorization, c.provider)
		return "", ErrUnavailable
	}
	outcome, err := c.archive.CompleteAppAttestEvidence(ctx, id, decision)
	if err != nil {
		c.integrity.Drop(c.authorization, c.provider)
		return "", err
	}
	if outcome != "verified" && action == "assertion" && c.authorization != nil {
		c.authorization.Forget(c.provider)
	}
	c.integrity.RecordCommit(action, outcome)
	return outcome, nil
}
