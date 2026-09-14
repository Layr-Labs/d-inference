package sandboxcontrol

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestSandboxSweepFailureLoggingIsBoundedAndReportsRecovery(t *testing.T) {
	var output bytes.Buffer
	now := time.Now()
	controller := &Controller{logger: slog.New(slog.NewTextHandler(&output, nil)), now: func() time.Time { return now }}
	failure := errors.New("test database unavailable")
	controller.recordSweepResult("lease_expiry", failure)
	for range 100 {
		controller.recordSweepResult("lease_expiry", failure)
	}
	if count := strings.Count(output.String(), "level=WARN"); count != 1 {
		t.Fatalf("duplicate warnings=%d", count)
	}
	now = now.Add(time.Minute)
	controller.recordSweepResult("lease_expiry", failure)
	controller.recordSweepResult("lease_expiry", context.Canceled)
	controller.recordSweepResult("lease_expiry", nil)
	controller.recordSweepResult("lease_expiry", nil)
	if strings.Count(output.String(), "level=WARN") != 2 || strings.Count(output.String(), "sandbox sweep recovered") != 1 {
		t.Fatalf("incorrect recovery/log throttle: %s", output.String())
	}
}
