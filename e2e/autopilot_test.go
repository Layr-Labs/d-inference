package e2e

import (
	"context"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// Uses an isolated coordinator/database and a real local provider. Enrollment
// applies only to the generated test TOML and the explicitly cached test model.
func TestIntegration_AutopilotCachedBootstrapAndPause(t *testing.T) {
	model := testbed.DefaultTestModelID()
	s := testbed.NewSuite(testbed.SuiteConfig{Autopilot: true,
		ModelSpecs: []testbed.ModelSpec{{ModelID: model, NumProviders: 1}}, NumUsers: 1, SeedBalance: 500_000_000})
	since := time.Now()
	require.NoError(t, s.Start(context.Background()))
	t.Cleanup(s.Stop)
	logProviders := func() {
		s.Coordinator.Registry.ForEachProviderVerification(func(p *registry.Provider, _ registry.Verification, models registry.PublicProviderModelSnapshot) {
			t.Logf("autopilot provider diagnostics: status=%s models=%v metrics=%+v autopilot=%+v",
				p.Status, models.Models, p.SystemMetrics, p.ModelAutopilot)
		})
	}
	t.Cleanup(func() {
		if t.Failed() {
			logProviders()
		}
	})
	ledger, ok := store.As[store.AutopilotStore](s.PgStore)
	require.True(t, ok)
	var events []store.AutopilotRecord
	waitTicks := 0
	require.Eventually(t, func() bool {
		waitTicks++
		if waitTicks%30 == 0 {
			logProviders()
		}
		var err error
		events, err = ledger.AutopilotRecords(s.Ctx, since, 100)
		if err != nil {
			return false
		}
		for _, event := range events {
			if event.Phase == "succeeded" && event.Load == model {
				return true
			}
		}
		return false
	}, 2*time.Minute, time.Second, "autopilot did not confirm a real cached load; events=%+v", events)
	var intent *store.AutopilotRecord
	for i := range events {
		if events[i].Phase == "reserved" {
			intent = &events[i]
			break
		}
	}
	require.NotNil(t, intent)
	require.Equal(t, model, intent.Load)
	require.Empty(t, intent.Unload, "empty bootstrap must not release anything")
	resp := postChatCompletionsWithModel(t, s, model, "Reply with one short word.", false, 16)
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode, string(body))
	require.True(t, s.Coordinator.Registry.SetAutopilotPaused(true))
	summary := s.Coordinator.Registry.TriggerAutopilot()
	require.Zero(t, summary.Issued)
	require.True(t, s.Coordinator.Registry.AutopilotSnapshot().Paused)
}
