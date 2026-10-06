package startup

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/config"
)

// InitializeLegacyMDMPolicy leaves nonproduction stores unfrozen so a later
// production startup captures membership at its own cutover, not during dev use.
func InitializeLegacyMDMPolicy(ctx context.Context, cfg config.AppConfig, owner *trust.Owner) error {
	if err := cfg.CheckDeploymentEnvironment(); err != nil {
		return err
	}
	if !cfg.RequiresProductionAppAttest() {
		return nil
	}
	return owner.InitializeLegacyMDMPolicy(ctx)
}
