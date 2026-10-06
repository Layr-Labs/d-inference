// Package exportconfig resolves the on-disk state export source.
package exportconfig

import (
	"github.com/eigeninference/d-inference/coordinator/env"
	"os"
)

const RootEnv = env.EnvPrefix + "_STATE_EXPORT_ROOT"

func Root() string {
	return env.FirstNonEmpty(os.Getenv(RootEnv), os.Getenv("USER_PERSISTENT_DATA_PATH"), "/mnt/disks/userdata")
}
