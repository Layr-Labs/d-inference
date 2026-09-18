package testbed

import (
	"context"
	"encoding/json"
	"os/exec"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

const prelaunchObservation = `observation={'gpu_temperature_c':42.75,'load1':1,'free_bytes':200*(1<<30),'unexpected_processes':[],'owned_processes':[]}
`

func TestOwnedPrelaunchRefusalRetainsObservationWithoutClaimingProviderStarted(t *testing.T) {
	target := targetFixture(t)
	script := `import sys,json,os
json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
` + prelaunchObservation + `
send({'event':'entry','fixture_pid':os.getpid(),'observation':observation,'entry_ready':False,'entry_reason':'GPU temperature exceeds 42 C or load1 exceeds 4'})
send({'event':'terminal','fixture_pid':os.getpid(),'provider_started':False,'pid':None,'exit_code':None,'failure':'prelaunch deadline expired','group_cleanup_complete':True})
send({'event':'cleanup','fixture_pid':os.getpid(),'provider_started':False,'observation':observation})
sys.exit(1)
`
	owner, err := startOwnedProvider(context.Background(), target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) })
	require.ErrorContains(t, err, "before provider start")
	require.NotContains(t, err.Error(), "lacks terminal receipt")
	require.NotContains(t, err.Error(), "lacks cleanup receipt")
	provider := &Provider{Target: &target, owned: owner}
	row := provider.HostLifecycle()
	require.Positive(t, row.HelperTransportPID)
	require.Positive(t, row.FixturePID)
	require.NotNil(t, row.ProviderStarted)
	require.False(t, *row.ProviderStarted)
	require.Zero(t, row.ProviderPID)
	require.Len(t, row.EntryChecks, 1)
	require.Equal(t, 42.75, row.EntryChecks[0].Observation.GPUTemperature)
	require.NotNil(t, row.Terminal)
	require.Nil(t, row.Terminal.ExitCode)
	require.NotNil(t, row.Cleanup)
	raw, err := json.Marshal(row)
	require.NoError(t, err)
	require.Contains(t, string(raw), `"provider_started":false`)
}

func TestOwnedPrelaunchCancellationWaitsForUnstartedTerminal(t *testing.T) {
	target := targetFixture(t)
	script := `import sys,json,os
json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
` + prelaunchObservation + `
send({'event':'entry','fixture_pid':os.getpid(),'observation':observation,'entry_ready':False,'entry_reason':'heat'})
for line in sys.stdin:
 if json.loads(line)['command']=='stop':break
send({'event':'terminal','fixture_pid':os.getpid(),'provider_started':False,'pid':None,'exit_code':None,'failure':None,'group_cleanup_complete':True})
send({'event':'cleanup','observation':observation})
`
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	owner, err := startOwnedProvider(ctx, target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) })
	require.ErrorIs(t, err, context.DeadlineExceeded)
	require.NotNil(t, owner)
	require.False(t, owner.running())
	require.NoError(t, owner.stop())
	require.Zero(t, owner.pid)
	require.NotNil(t, owner.terminal)
	require.NotNil(t, owner.cleanup)
}

func TestOwnedPrelaunchReceivesLeasePingBeforeProviderStart(t *testing.T) {
	target := targetFixture(t)
	script := `import sys,json,os,select
json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
` + prelaunchObservation + `
send({'event':'entry','fixture_pid':os.getpid(),'observation':observation,'entry_ready':False,'entry_reason':'heat'})
ready,_,_=select.select([sys.stdin],[],[],7)
if not ready or json.loads(sys.stdin.readline())['command']!='ping':sys.exit(3)
observation['gpu_temperature_c']=30
send({'event':'entry','fixture_pid':os.getpid(),'observation':observation,'entry_ready':True,'entry_reason':None})
send({'event':'prepared','host_id':'fixture','observation':observation})
send({'event':'started','pid':os.getpid()})
for line in sys.stdin:
 if json.loads(line)['command']=='stop':break
send({'event':'terminal','pid':os.getpid(),'exit_code':0,'failure':None})
send({'event':'cleanup','observation':observation})
`
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	owner, err := startOwnedProvider(ctx, target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) })
	require.NoError(t, err)
	require.NoError(t, owner.stop())
	require.Len(t, owner.entryChecks, 2)
	require.False(t, owner.entryChecks[0].Ready)
	require.True(t, owner.entryChecks[1].Ready)
}

func TestHostLifecyclesRetainsUnattemptedTargets(t *testing.T) {
	target := targetFixture(t)
	suite := &Suite{Config: SuiteConfig{ProviderTargets: []ProviderTarget{target, target}}}
	rows := suite.HostLifecycles()
	require.Len(t, rows, 2)
	for _, row := range rows {
		require.NotNil(t, row.ProviderStarted)
		require.False(t, *row.ProviderStarted)
		require.Zero(t, row.HelperTransportPID)
		require.Nil(t, row.Terminal)
	}
}

func TestOwnedAlreadyCancelledContextNeverStartsHelper(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	owner, err := startOwnedProvider(ctx, targetFixture(t), ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { called = true; return nil })
	require.ErrorIs(t, err, context.Canceled)
	require.Nil(t, owner)
	require.False(t, called)
}

func TestEntryReadinessRejectsRecordedNonfiniteMeasurement(t *testing.T) {
	observation := HostObservation{GPUTemperature: 0, Load1: 1, FreeBytes: 200 * (1 << 30), MeasurementErrors: map[string]string{"gpu_temperature_c": "nan"}}
	require.ErrorContains(t, observation.EntryReady(), "invalid host measurements")
}
