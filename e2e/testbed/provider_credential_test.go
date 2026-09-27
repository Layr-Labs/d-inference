package testbed

import (
	"context"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOwnedForeignCleanupRetainsCredentialRetirementFact(t *testing.T) {
	target := targetFixture(t)
	script := `import sys,json,os
json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
observation={'gpu_temperature_c':30,'load1':1,'free_bytes':200*(1<<30),'unexpected_processes':[],'owned_processes':[]}
send({'event':'prepared','host_id':'fixture','observation':observation})
send({'event':'started','pid':os.getpid()})
for line in sys.stdin:
 if json.loads(line)['command']=='stop':break
send({'event':'terminal','pid':os.getpid(),'exit_code':0,'failure':None})
observation['unexpected_processes']=[14340]
send({'event':'cleanup','auth_token_retired':True,'auth_token_retirement_error':None,'observation':observation})
sys.exit(1)
`
	owner, err := startOwnedProvider(context.Background(), target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) })
	require.NoError(t, err)
	require.ErrorContains(t, owner.stop(), "host has process leftovers")
	row := (&Provider{Target: &target, owned: owner}).HostLifecycle()
	require.NotNil(t, row.AuthTokenRetired)
	require.True(t, *row.AuthTokenRetired)
	require.Nil(t, row.AuthTokenRetirementError)
	require.Equal(t, []int{14340}, row.Cleanup.UnexpectedProcesses)
	require.NotEmpty(t, row.ControlError)
}
