package e2e

import (
	"bytes"
	"context"
	"encoding/json"
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
// The testbed seeds a trusted inventory fixture for its authenticated provider;
// this exercises persisted machine selection and real acknowledgements, not Apple trust.
func TestIntegration_AutopilotCachedBootstrapAndPause(t *testing.T) {
	model := testbed.DefaultTestModelID()
	s := testbed.NewSuite(testbed.SuiteConfig{Autopilot: true,
		ModelSpecs: []testbed.ModelSpec{{ModelID: model, NumProviders: 1}}, NumUsers: 1, SeedBalance: 500_000_000})
	since := time.Now()
	require.NoError(t, s.Start(context.Background()))
	t.Cleanup(s.Stop)
	providers, err := s.BoundProviders()
	require.NoError(t, err)
	require.Len(t, providers, 1)
	account, machine := providers[0].GetVerifiedMachineIdentity()
	require.Equal(t, s.Providers[0].AccountID, account)
	require.NotEmpty(t, machine)
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
	settings, ok := store.As[store.MachineAutopilotStore](s.PgStore)
	require.True(t, ok)
	live, err := settings.LiveMachineAutopilotSettings(s.Ctx)
	require.NoError(t, err)
	require.Equal(t, []store.MachineAutopilotSetting{{
		MachineID: machine, DesiredMode: store.MachineAutopilotLive, Revision: 1,
	}}, live)
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
			if event.ProviderID == providers[0].ID && event.Phase == "succeeded" && event.Load == model {
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
	require.Equal(t, providers[0].ID, intent.ProviderID)
	require.Equal(t, model, intent.Load)
	require.Empty(t, intent.Unload, "empty bootstrap must not release anything")
	cohort := s.Coordinator.Registry.AutopilotSnapshot()
	require.False(t, cohort.ObserveOnly)
	require.Equal(t, 1, cohort.LiveCohort)
	require.Equal(t, 1, cohort.LiveActive, "cached load must follow a real live-lease acknowledgement")
	require.Zero(t, cohort.Shadow)
	resp := postChatCompletionsWithModel(t, s, model, "Reply with one short word.", false, 16)
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode, string(body))

	setMode := func(mode store.MachineAutopilotMode) registry.MachineAutopilotStatus {
		t.Helper()
		payload, err := json.Marshal(map[string]store.MachineAutopilotMode{"desired_mode": mode})
		require.NoError(t, err)
		req, err := http.NewRequestWithContext(s.Ctx, http.MethodPatch,
			s.Coordinator.BaseURL()+"/v1/admin/autopilot/machines/"+machine, bytes.NewReader(payload))
		require.NoError(t, err)
		req.Header.Set("Authorization", "Bearer testbed-admin-key")
		req.Header.Set("Content-Type", "application/json")
		client := &http.Client{Timeout: 5 * time.Second}
		resp, err := client.Do(req)
		require.NoError(t, err)
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		require.NoError(t, err)
		require.Equal(t, http.StatusOK, resp.StatusCode, string(body))
		var result struct {
			Machine registry.MachineAutopilotStatus `json:"machine"`
		}
		require.NoError(t, json.Unmarshal(body, &result))
		require.Equal(t, machine, result.Machine.MachineID)
		require.Equal(t, mode, result.Machine.DesiredMode)
		return result.Machine
	}
	shadow := setMode(store.MachineAutopilotShadow)
	require.EqualValues(t, 2, shadow.Revision)
	require.Len(t, shadow.Sessions, 1)
	require.Equal(t, providers[0].ID, shadow.Sessions[0].ProviderID)
	require.Equal(t, "shadow", shadow.Sessions[0].EffectiveMode)
	require.False(t, shadow.Sessions[0].ControlActive)
	live, err = settings.LiveMachineAutopilotSettings(s.Ctx)
	require.NoError(t, err)
	require.Empty(t, live, "admin demotion must persist, not only revoke a local lease")
	reenabled := setMode(store.MachineAutopilotLive)
	require.EqualValues(t, 3, reenabled.Revision)
	require.Eventually(t, func() bool {
		return s.Coordinator.Registry.TriggerAutopilot().LiveActive == 1
	}, 20*time.Second, 100*time.Millisecond, "re-enabled machine did not acknowledge fresh live control")

	require.True(t, s.Coordinator.Registry.SetAutopilotPaused(true))
	summary := s.Coordinator.Registry.TriggerAutopilot()
	require.Zero(t, summary.Issued)
	require.True(t, s.Coordinator.Registry.AutopilotSnapshot().Paused)
	live, err = settings.LiveMachineAutopilotSettings(s.Ctx)
	require.NoError(t, err)
	require.Equal(t, []store.MachineAutopilotSetting{{
		MachineID: machine, DesiredMode: store.MachineAutopilotLive, Revision: 3,
	}}, live, "global pause must not erase durable machine intent")
}
