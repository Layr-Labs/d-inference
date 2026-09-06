package testbed

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/stretchr/testify/require"
)

func targetFixture(t *testing.T) ProviderTarget {
	t.Helper()
	row := ProviderFile{SHA256: strings.Repeat("a", 64), Bytes: 3, Mode: 0644}
	binary := row
	binary.Mode = 0755
	return ProviderTarget{Name: "host_a", Root: filepath.Join(t.TempDir(), "new-owned-root"), RuntimeDirectory: "/owned/runtime",
		RuntimeFiles:          map[string]ProviderFile{"darkbloom": binary, "mlx.metallib": row},
		Models:                []ProviderModelInput{{ID: "org/model", Snapshot: "/owned/model", Files: map[string]ProviderFile{"config.json": row}}},
		CanonicalConfigSHA256: row.SHA256, HardwareModel: "MacFixture,1", MemoryBytes: 36 << 30, MacmonPath: "/owned/macmon", Macmon: binary}
}

func TestProviderTargetsRefuseBeforeCoordinatorOrProcessWork(t *testing.T) {
	target := targetFixture(t)
	require.NoError(t, ValidateProviderTargets([]ProviderTarget{target}, 1))
	for _, change := range []func(*ProviderTarget){
		func(v *ProviderTarget) { v.Root = "/owned/../default" },
		func(v *ProviderTarget) { v.Name = "$(not-a-command)" },
		func(v *ProviderTarget) { v.RuntimeFiles["auth_token"] = ProviderFile{SHA256: strings.Repeat("a", 64)} },
		func(v *ProviderTarget) {
			v.SSH = &ProviderSSH{Destination: "-oProxyCommand=bad", IdentityFile: "/key", Python: "/usr/bin/python3", ForwardPort: 1234}
		},
		func(v *ProviderTarget) {
			v.SSH = &ProviderSSH{Destination: "user@host", IdentityFile: "relative", Python: "/usr/bin/python3", ForwardPort: 1234}
		},
	} {
		candidate := targetFixture(t)
		change(&candidate)
		suite := NewSuite(SuiteConfig{ModelSpecs: []ModelSpec{{ModelID: "org/model", NumProviders: 1}}, ProviderTargets: []ProviderTarget{candidate}})
		require.Error(t, suite.Start(context.Background()))
		require.Nil(t, suite.Coordinator)
		require.Empty(t, suite.Providers)
	}
	require.Error(t, ValidateProviderTargets([]ProviderTarget{target, target}, 2))
	require.Error(t, ValidateProviderTargets([]ProviderTarget{}, 1))
	require.NoError(t, ValidateProviderTargets(nil, 1))
}

func TestProviderLaunchSpecKeepsPathsAndTokensOutOfArgv(t *testing.T) {
	root := filepath.Join(t.TempDir(), "literal $(text) ' `backticks`")
	cfg := ProviderConfig{ModelIDs: []string{"org/model"}, AuthTokenPath: filepath.Join(root, "auth_token"), KVBackend: "paged", MaxConcurrent: 2, MTPMode: "on", EnableEphemeralPrefixCache: true, PrefixCacheMode: "ssd"}
	spec, err := buildProviderStartSpec("http://127.0.0.1:8123", root, cfg, 0)
	require.NoError(t, err)
	require.Equal(t, []string{"start", "--foreground", "--coordinator-url", "ws://127.0.0.1:8123/ws/provider", "--model", "org/model", "--config", filepath.Join(root, "provider.toml")}, spec.Arguments)
	require.Equal(t, filepath.Join(root, "prefix-cache"), spec.Environment["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"])
	require.Equal(t, "1", spec.Environment["DARKBLOOM_PREFIX_CACHE"])
	require.NotContains(t, strings.Join(spec.Arguments, " "), "auth_token")
	require.Contains(t, spec.Config, "auto_update = false")
	require.Contains(t, spec.Config, "auto_restart = false")
	for _, url := range []string{"https://user:secret@host", "http://127.0.0.1:1/admin", "file:///tmp/x", "http://127.0.0.1:1/?token=secret"} {
		_, err := buildProviderStartSpec(url, root, cfg, 0)
		require.Error(t, err)
	}
}

func TestProviderSSHArgumentsUseLoopbackAndShellQuotedStaticSource(t *testing.T) {
	target := targetFixture(t)
	target.SSH = &ProviderSSH{Destination: "gaj@100.64.0.1", IdentityFile: "/owned/key with spaces", Python: "/owned/python 'literal'", ForwardPort: 54321}
	name, args, err := ownedHostCommand(target, "http://127.0.0.1:8765")
	require.NoError(t, err)
	require.Equal(t, "ssh", name)
	require.Contains(t, args, "127.0.0.1:54321:127.0.0.1:8765")
	require.Contains(t, args, "ExitOnForwardFailure=yes")
	require.Contains(t, args, "/owned/key with spaces")
	require.Contains(t, args[len(args)-1], shellWord(target.SSH.Python))
	for _, url := range []string{"http://0.0.0.0:8765", "http://example.com:8765", "http://127.0.0.1:8765/admin", "http://127.0.0.1:0", "http://127.0.0.1:65536"} {
		_, _, err := ownedHostCommand(target, url)
		require.Error(t, err)
	}
	literal := "$HOME `not-a-command` $(not-a-command) 'single' \"double\""
	output, err := exec.Command("sh", "-c", "printf '%s' "+shellWord(literal)).Output()
	require.NoError(t, err)
	require.Equal(t, literal, string(output))
}

func TestProviderEntryHeatAndCleanupHaveDifferentPredicates(t *testing.T) {
	value := HostObservation{GPUTemperature: 41, Load1: 1, FreeBytes: 200 << 30}
	require.NoError(t, value.EntryReady())
	require.NoError(t, value.CleanupComplete())
	value.GPUTemperature = 55
	require.Error(t, value.EntryReady())
	require.NoError(t, value.CleanupComplete(), "successful hot work is clean")
	value.OwnedProcesses = []int{123}
	require.Error(t, value.CleanupComplete())
	value.OwnedProcesses = nil
	value.GPUTemperature = math.NaN()
	require.Error(t, value.EntryReady())
	value.GPUTemperature = 25
	value.UnexpectedProcesses = []int{456}
	require.Error(t, value.EntryReady())
	require.Error(t, value.CleanupComplete())
}

func TestProviderBindingsUseAccountsAcrossRegistrationOrderAndReconnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	suite := &Suite{Config: SuiteConfig{ProviderTargets: []ProviderTarget{{Name: "a"}, {Name: "b"}}}, Coordinator: &Coordinator{Registry: reg}, Providers: []*Provider{
		{Target: &ProviderTarget{Name: "a"}, AccountID: "account-a", owned: &ownedProvider{hostID: "physical-a"}},
		{Target: &ProviderTarget{Name: "b"}, AccountID: "account-b", owned: &ownedProvider{hostID: "physical-b"}},
	}}
	b := reg.Register("b-first", nil, &protocol.RegisterMessage{})
	b.AccountID = "account-b"
	a := reg.Register("a-second", nil, &protocol.RegisterMessage{})
	a.AccountID = "account-a"
	bound, err := suite.BoundProviders()
	require.NoError(t, err)
	require.Equal(t, []*registry.Provider{a, b}, bound)
	reg.Disconnect(a.ID)
	again := reg.Register("a-reconnected", nil, &protocol.RegisterMessage{})
	again.AccountID = "account-a"
	bound, err = suite.BoundProviders()
	require.NoError(t, err)
	require.Equal(t, again, bound[0])
	suite.Providers[1].owned.hostID = "physical-a"
	_, err = suite.BoundProviders()
	require.Error(t, err, "aliases of one machine cannot prove two hosts")
}

func TestProviderOwnedAdapterUsesInjectedSSHAndRetainsHotCleanup(t *testing.T) {
	target := targetFixture(t)
	target.SSH = &ProviderSSH{Destination: "user@host", IdentityFile: "/owned/key", Python: "/usr/bin/python3", ForwardPort: 54321}
	script := `import sys,json,base64,os
request=json.loads(sys.stdin.readline())
def send(x):print(json.dumps(x),flush=True)
observation={'gpu_temperature_c':55,'load1':1,'free_bytes':200*(1<<30),'unexpected_processes':[],'owned_processes':[]}
send({'event':'prepared','host_id':'physical-test','observation':observation})
send({'event':'started','pid':os.getpid()})
for line in sys.stdin:
 message=json.loads(line);command=message['command']
 if command=='state':send({'event':'state','id':message['id'],'body':base64.b64encode(b'{"ready":true}').decode()})
 if command=='observe':send({'event':'observation','id':message['id'],'observation':observation})
 if command=='stop':break
send({'event':'terminal','pid':os.getpid(),'exit_code':0,'failure':None})
send({'event':'cleanup','observation':observation})
`
	calls := 0
	factory := func(name string, args ...string) *exec.Cmd {
		calls++
		require.Equal(t, "ssh", name)
		require.NotContains(t, strings.Join(args, " "), "PRIVATE_FIXTURE_TOKEN")
		return exec.Command("python3", "-u", "-c", script)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	spec, err := buildProviderStartSpec("http://127.0.0.1:54321", target.Root, ProviderConfig{ModelIDs: []string{"org/model"}}, 0)
	require.NoError(t, err)
	owner, err := startOwnedProvider(ctx, target, spec, []byte("PRIVATE_FIXTURE_TOKEN"), "suite-nonce", "http://127.0.0.1:8765", factory)
	require.NoError(t, err)
	require.Equal(t, 1, calls)
	raw, err := owner.readState(ctx)
	require.NoError(t, err)
	require.JSONEq(t, `{"ready":true}`, string(raw))
	require.NoError(t, owner.stop())
	require.False(t, owner.running())
	require.NotNil(t, owner.cleanup)
	require.Equal(t, 55.0, owner.cleanup.GPUTemperature)
	require.NoError(t, owner.stop(), "cleanup is idempotent")
}

func TestProviderOwnedAdapterRefusesPartialHelperBeforeReady(t *testing.T) {
	target := targetFixture(t)
	factory := func(string, ...string) *exec.Cmd {
		return exec.Command("python3", "-c", `print('{"event":"prepared","host_id":"partial"}',flush=True)`)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	owner, err := startOwnedProvider(ctx, target, ProviderStartSpec{}, []byte("fixture-token"), "suite-nonce", "http://127.0.0.1:1", factory)
	require.Error(t, err)
	require.NotNil(t, owner)
	require.Error(t, owner.stop())
	var event ownedHostEvent
	require.NoError(t, json.Unmarshal([]byte(`{"event":"terminal","exit_code":null}`), &event))
	require.Nil(t, event.ExitCode)
}

func controlFixtureOwner(t *testing.T, behavior string) *ownedProvider {
	t.Helper()
	target := targetFixture(t)
	script := `import sys,json,os,base64,time
request=json.loads(sys.stdin.readline())
def send(x):print(json.dumps(x),flush=True)
observation={'gpu_temperature_c':30,'load1':1,'free_bytes':200*(1<<30),'unexpected_processes':[],'owned_processes':[]}
send({'event':'prepared','host_id':'fixture','observation':observation})
send({'event':'started','pid':os.getpid()})
count=0
for line in sys.stdin:
 message=json.loads(line);command=message['command']
 if command=='ping':continue
 if command=='stop':break
 count+=1
` + behavior + `
send({'event':'terminal','pid':os.getpid(),'exit_code':0,'failure':None})
send({'event':'cleanup','observation':observation})
`
	factory := func(string, ...string) *exec.Cmd { return exec.Command("python3", "-u", "-c", script) }
	owner, err := startOwnedProvider(context.Background(), target, ProviderStartSpec{}, []byte("fixture-token"), "nonce", "http://127.0.0.1:1", factory)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, owner.stop()) })
	return owner
}

func TestProviderMissingStateIsRetryableOnSameOwnedChild(t *testing.T) {
	owner := controlFixtureOwner(t, ` if count==1:send({'event':'state','id':message['id'],'error':'not_ready','retryable':True})
 else:send({'event':'state','id':message['id'],'body':base64.b64encode(b'{"ready":true}').decode()})`)
	_, err := owner.readState(context.Background())
	require.ErrorIs(t, err, os.ErrNotExist)
	require.True(t, owner.running())
	raw, err := owner.readState(context.Background())
	require.NoError(t, err)
	require.JSONEq(t, `{"ready":true}`, string(raw))
	require.True(t, owner.running())
}

func TestProviderDelayedRetiredResponseCannotSupplyNextStateOrObservation(t *testing.T) {
	owner := controlFixtureOwner(t, ` if count==1:time.sleep(0.1)
 if command=='state':send({'event':'state','id':message['id'],'body':base64.b64encode(json.dumps({'reply':count}).encode()).decode()})
 else:send({'event':'observation','id':message['id'],'observation':observation})`)
	cancelled, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	_, err := owner.readState(cancelled)
	require.ErrorIs(t, err, context.DeadlineExceeded)
	raw, err := owner.readState(context.Background())
	require.NoError(t, err)
	require.JSONEq(t, `{"reply":2}`, string(raw))
	event, err := owner.request(context.Background(), "observe", "observation", time.Second)
	require.NoError(t, err)
	require.Equal(t, uint64(3), event.RequestID)
}

func TestProviderLaunchDefaultCacheDoesNotInstallGlobalOverride(t *testing.T) {
	spec, err := buildProviderStartSpec("http://127.0.0.1:8123", t.TempDir(), ProviderConfig{ModelIDs: []string{"gpt-oss-20b"}, KVBackend: "auto", MTPMode: "auto", MaxConcurrent: 1, EnableEphemeralPrefixCache: true}, 0)
	require.NoError(t, err)
	require.NotContains(t, spec.Environment, "DARKBLOOM_PREFIX_CACHE")
	require.NotContains(t, spec.Environment, "DARKBLOOM_PREFIX_CACHE_MEMORY")
	require.Equal(t, "1", spec.Environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"])
	require.Contains(t, spec.Config, `mtp_mode = "auto"`)
	require.Contains(t, spec.Config, `engine_v2_kv_backend = "auto"`)
}
