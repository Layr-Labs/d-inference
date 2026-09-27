package testbed

import (
	"context"
	"encoding/json"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOwnedProviderRetiredWithoutStartAcknowledgement(t *testing.T) {
	target := targetFixture(t)
	script := `import sys,json,os,subprocess
json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
observation={'gpu_temperature_c':30,'load1':1,'free_bytes':200*(1<<30),'unexpected_processes':[],'owned_processes':[]}
send({'event':'prepared','fixture_pid':os.getpid(),'host_id':'fixture','observation':observation})
child=subprocess.Popen([sys.executable,'-c','pass'],start_new_session=True)
child.wait()
# Model the signal window after Popen ownership was recorded but before the
# start acknowledgement reached Go. This is a harmless child, not a provider.
send({'event':'terminal','fixture_pid':os.getpid(),'provider_started':True,'pid':child.pid,'pgid':child.pid,'exit_code':0,'failure':None,'group_cleanup_complete':True,'root_created':True})
send({'event':'cleanup','fixture_pid':os.getpid(),'observation':observation})
`
	owner, err := startOwnedProvider(context.Background(), target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) })
	require.ErrorContains(t, err, "start acknowledgement")
	require.NotNil(t, owner)
	require.False(t, owner.running())
	require.Zero(t, owner.pid, "terminal proof must not authorize normal startup")
	select {
	case <-owner.started:
		t.Fatal("terminal closed the startup acknowledgement channel")
	default:
	}
	row := (&Provider{Target: &target, owned: owner}).HostLifecycle()
	require.NotNil(t, row.ProviderStarted)
	require.True(t, *row.ProviderStarted)
	require.Positive(t, row.ProviderPID)
	require.Equal(t, row.Terminal.PID, row.ProviderPID)
	require.Equal(t, row.Terminal.PGID, row.ProviderPID)
	require.False(t, row.StartAcknowledged)
	require.Empty(t, row.StartupIdentityError)
	raw, err := json.Marshal(row)
	require.NoError(t, err)
	require.Contains(t, string(raw), `"provider_started":true`)
	require.Contains(t, string(raw), `"start_acknowledged":false`)
}

func TestProviderStartupIdentityRejectsContradictoryTerminal(t *testing.T) {
	zero := 0
	cases := []struct {
		name        string
		ack         int
		terminal    *ownedHostEvent
		wantPID     int
		wantStarted *bool
		wantError   bool
	}{
		{"missing_ack_and_terminal", 0, nil, 0, nil, false},
		{"retired_without_ack", 0, &ownedHostEvent{ProviderStarted: startupBool(true), PID: 42, PGID: 42, ExitCode: &zero}, 42, startupBool(true), false},
		{"explicit_unstarted", 0, &ownedHostEvent{ProviderStarted: startupBool(false)}, 0, startupBool(false), false},
		{"zero_started_pid", 0, &ownedHostEvent{ProviderStarted: startupBool(true)}, 0, nil, true},
		{"different_group", 0, &ownedHostEvent{ProviderStarted: startupBool(true), PID: 42, PGID: 43}, 0, nil, true},
		{"different_ack_pid", 41, &ownedHostEvent{ProviderStarted: startupBool(true), PID: 42, PGID: 42}, 41, startupBool(true), true},
		{"unstarted_conflicts_with_ack", 41, &ownedHostEvent{ProviderStarted: startupBool(false)}, 41, startupBool(true), true},
		{"unstarted_has_pid", 0, &ownedHostEvent{ProviderStarted: startupBool(false), PID: 42}, 0, nil, true},
		{"unstarted_has_exit", 0, &ownedHostEvent{ProviderStarted: startupBool(false), ExitCode: &zero}, 0, nil, true},
		{"missing_flag_without_ack", 0, &ownedHostEvent{PID: 42, PGID: 42, ExitCode: &zero}, 0, nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			started, pid, err := providerStartupIdentity(tc.ack, tc.terminal)
			require.Equal(t, tc.wantStarted, started)
			require.Equal(t, tc.wantPID, pid)
			if tc.wantError {
				require.ErrorContains(t, err, "contradictory provider startup identity")
			} else {
				require.NoError(t, err)
			}
		})
	}
}

func TestHostLifecycleWithoutAckOrTerminalIsUnknown(t *testing.T) {
	row := (&Provider{owned: &ownedProvider{cmd: &exec.Cmd{}}}).HostLifecycle()
	require.Nil(t, row.ProviderStarted)
	require.False(t, row.StartAcknowledged)
	raw, err := json.Marshal(row)
	require.NoError(t, err)
	require.Contains(t, string(raw), `"provider_started":null`)
}

func TestOwnedContradictoryTerminalRetainsAcknowledgedStartAndError(t *testing.T) {
	target := targetFixture(t)
	script := `import sys,json,os,subprocess
json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
observation={'gpu_temperature_c':30,'load1':1,'free_bytes':200*(1<<30),'unexpected_processes':[],'owned_processes':[]}
send({'event':'prepared','fixture_pid':os.getpid(),'host_id':'fixture','observation':observation})
child=subprocess.Popen([sys.executable,'-c','pass'],start_new_session=True)
send({'event':'started','fixture_pid':os.getpid(),'pid':child.pid,'pgid':child.pid})
child.wait()
send({'event':'terminal','fixture_pid':os.getpid(),'provider_started':True,'pid':child.pid+1,'pgid':child.pid+1,'exit_code':0,'failure':None,'group_cleanup_complete':True,'root_created':True})
send({'event':'cleanup','observation':observation})
`
	owner, _ := startOwnedProvider(context.Background(), target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) })
	require.NotNil(t, owner)
	require.ErrorContains(t, owner.stop(), "contradictory provider startup identity")
	row := (&Provider{Target: &target, owned: owner}).HostLifecycle()
	require.NotNil(t, row.ProviderStarted)
	require.True(t, *row.ProviderStarted)
	require.True(t, row.StartAcknowledged)
	require.Equal(t, owner.pid, row.ProviderPID)
	require.NotEqual(t, row.Terminal.PID, row.ProviderPID)
	require.NotEmpty(t, row.StartupIdentityError)
	require.Contains(t, row.ControlError, "contradictory provider startup identity")
}
