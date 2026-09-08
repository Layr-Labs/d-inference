package config

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
)

func TestAppConfigRejectsInvalidProcessPostureMode(t *testing.T) {
	t.Setenv(api.ProcessPostureModeEnv, "shdaow")
	err := ReadAppConfig().Check()
	if err == nil || !strings.Contains(err.Error(), api.ProcessPostureModeEnv) {
		t.Fatalf("invalid mode did not reach startup validation: %v", err)
	}
}
