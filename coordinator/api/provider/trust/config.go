package trust

import (
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
)

type MDMSchedulerConfig = verification.Config

func ReadMDMSchedulerConfig() MDMSchedulerConfig { return verification.ReadConfig() }
