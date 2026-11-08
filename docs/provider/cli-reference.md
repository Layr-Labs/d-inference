# Provider CLI reference

> Last updated: 2026-11-08

Reference for the `darkbloom` command-line tool: every subcommand and flag, the
files and identifiers it creates, the `provider.toml` keys it reads with their
defaults, the environment variables it forwards to the daemon, and its runtime
constants, as declared in `provider-swift/Sources/darkbloom/` (`Darkbloom`,
version `ProviderCore.version` in
`provider-swift/Sources/ProviderCore/ProviderCore.swift`). For operators; types
and defaults are the ArgumentParser declarations; `—` means required.

`waiting_inventory` means a selected model's ordinary update introduced an ID
outside the Autopilot set. Enrollment remains saved, ordinary serving
continues, and the update's verified prefetch or `darkbloom autopilot models`
adds it to the set before control can resume. Waiting and shadow Autopilot preserve the normal picker and `--model` serving selection. Other verified cached models are reported separately for planning and cannot be loaded by ordinary routing. See [Autopilot architecture](../architecture/model-autopilot.md).

## Local GLM qualification

`darkbloom start --local --model EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`
can include the experimental GLM root only when
`DARKBLOOM_EXPERIMENTAL_GLM5_NEXT` names an absolute qualification JSON file.
Unset, empty, `1`, malformed selections and mismatched identities refuse GLM.
The file pins the exact catalog record, manifest and expected aggregate; see
[configuration](../reference/configuration.md#local-glm-qualification) for its schema.
GLM always uses its native paged KV backend: automatic selection resolves
`paged`, and an explicit `contiguous` selection or the `DARKBLOOM_CBV2_PAGED_KV`
kill switch refuses the load instead of falling back. GLM serves only through
its embedded-MTP engine, which is on by default: the default `mtp_mode = "auto"`
enables it without any setting (`MTPMode.enablesMTP`). `mtp_mode = "off"` or
the `DARKBLOOM_CBV2_MTP=0` kill switch skips the model at startup with a
message, because GLM cannot serve target-only. This opt-in does not select a performance profile,
bypass memory admission or qualify the model. It is not forwarded into launchd.
Stop the isolated local process to disable it. There is no target-only GLM
serving engine; target-only construction is limited to benchmarks.

Every GLM load uses the native `GLM5NextExecutionPolicy.serving` arithmetic
(absorbed sparse attention with native decode selection and sparse prefill kernels,
parallel-threshold selection, native KDA
recurrence, fused hyper-connections and routed-expert combine), recorded in the
encrypted checkpoint identity. The encrypted SSD prefix store defaults on for
`EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`; `DARKBLOOM_PREFIX_CACHE=0` opts out.
GLM MTP verifies up to three drafted tokens per round in one target forward with
an adaptive depth; its greedy output is not token-identical to target-only
decode. `DARKBLOOM_GLM_RECTANGULAR_VERIFY=0` selects serial single-proposal
verification instead.
Prefill chunks and steps are each at most 2,048 tokens, and solo prefill stripes are off, including
`DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE`. While other requests decode, each prompt chunk is followed by
decode-only steps; `DARKBLOOM_GLM_DECODE_STEPS_BETWEEN_CHUNKS` sets how many
([default and range](../reference/configuration.md#engine-and-scheduler)), and `0` restores a chunk in
every step. Requests that omit sampling fields use the
artifact's `generation_config.json` (temperature 1.0, top_p 0.95). Image input
runs through the native GLM media path; the embedded-MTP serving engine accepts
prepared causal media, so image rows prefill and decode target-only (no MTP
speculation, no prefix reuse). Video input (`video_url` with an inline `data:video/mp4` or `data:video/quicktime` URL, constant or variable frame rate) is sampled at 2 FPS and decoded target-only.
This variable never advertises the local identity to the coordinator
(`provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextLocalQualification.swift`,
`GLM5NextLocalQualification`). Coordinator-connected `darkbloom start` serves
only the catalog build `glm-5.3-flash`, downloaded by the normal revision path,
on Apple M5 Max or M5 Ultra with at least 256 GB; other Macs report the exact
refusal (chip and memory) in the load error and `doctor`
(`provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextCoordinatorServing.swift`,
`GLM5NextCoordinatorServing`; `provider-swift/Sources/ProviderCore/Models/GLM5NextHardwareRequirement.swift`).
`--local` does not serve the catalog build; use the selection file above.

## `darkbloom cache`

Persistent settings for encrypted inference caches; downloaded model weights use
[`darkbloom models location`](#darkbloom-models-location) separately. Changes apply
when serving starts again. Commands use `--config` and never migrate, erase,
format or mount a disk (`provider-swift/Sources/darkbloom/Cache/CacheCommand.swift`,
`Cache`; `Cache/CacheConfiguration.swift`, `updateCacheSettings`).

| Command / flag | Behavior |
|---|---|
| `cache status` | Read saved settings and inspect the selected volume without loading keys or creating cache directories |
| `cache status --json` | Emit directory, saved daily byte limit and unlimited flag (omitted when unset), limit source, selected volume details, storage problem and `saved_settings` scope |
| `cache set --daily-write-gb <number>` | Save the rolling-day write ceiling in decimal GB; `0` explicitly selects unlimited writes |
| `cache set --directory <absolute-path>` | Select an existing private directory and pin its volume UUID. Payloads live in its `darkbloom/kv3` subtree (a dev build: its own namespace) |
| `cache set --reset-directory` | Return to the built-in directory; preserve the daily write choice and existing cache files |

Both setting flags can be combined. The saved daily choice takes precedence over
`DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY`, including an older value baked
into launchd. When no daily choice is saved, the environment/default rules in
[configuration](../reference/configuration.md#ssd-prefix-cache) still apply.
Invalid, missing or changed selected storage disables SSD caching; inference can
continue cold. See [selecting cache storage](cache-storage.md) for disk preparation,
limits and verification. These checks do not certify disk firmware.

## Desktop frontend control

`darkbloom desktop serve --config <path>` runs the authenticated loopback API.
`darkbloom desktop ensure --config <path>` installs/starts its user LaunchAgent,
reinstalling it when the plist changed and restarting it once when the running
API reports a different version than the invoking CLI.
The desktop frontend sends validated actions to existing CLI operations and
keeps the provider independent of its window lifetime. On a Mac in a two-Mac
cluster its Stop and Restart run `darkbloom stop` and `darkbloom restart`, which
act on both Macs; its local mode serves this Mac alone, so `desktop start-local`
refuses there and says why instead of reporting a start (`Desktop.StartLocal.pairRefusal`). Internal
`desktop start-local --model <id>`, `stop-local`, and `restart-local` commands
(each accepting `--config`) retain the native provider owner and termination handler. `start-local` serves on
this Mac's one local API port (`Desktop.StartLocal.localAPI`, `LocalAPIPort.choose`): `[local] port`, else the one
its local API already uses, else one chosen, all before anything stops (no free port starts nothing). A port not
saved yet is saved only once the service started (`Desktop.StartLocal.serve`): a refused drain or a failed install
saves nothing. Its LaunchAgent runs `start --foreground --local --port <n> --bind
<address>` (`LaunchAgent.localProgramArguments`), which never asks or saves and prints no key. Cooling uses
`desktop configure-cooling --enabled <bool> --speed <percent> --temperature <celsius>`
to request macOS administrator authorization for the existing signed helper.
`darkbloom desktop login [--config <path>]` signs into the account
workspace through browser approval; `darkbloom desktop logout [--config <path>]`
signs out without changing provider linkage or serving state. Both use the same
CLI and native account store as Electron (`Desktop.Login`, `Desktop.Logout`).
It prefers a scoped account session and supports existing coordinator device-code
grants when the desktop scope is not reported. Dashboard credentials stay separate
from the running provider (`DeviceLoginScope`, `DesktopAccountCredential`).
See [desktop control](../reference/desktop-control.md) for the exact routes,
credentials, outcomes, and limits (`Desktop`, `DesktopBackend`).

## Global options

The hidden `--native-serve-qualification-v1 <ws-url> <private-directory>` entry
is an explicitly enabled physical diagnostic, not an installed-service command.
`NativeServeQualificationCommand` in
`provider-swift/Sources/darkbloom/NativeServeQualificationCommand.swift` runs a
separate AppKit host without `Start`, APNs registration or daemon replacement.
It requires `DARKBLOOM_NATIVE_SERVE_QUALIFICATION=1`, a signed release app,
literal `127.0.0.1` WebSocket transport and owner-only inputs. See
[native serving qualification](../developer/test.md#native-serving-qualification)
for isolation, evidence and untested-scope limits.

Every `darkbloom` invocation on macOS below 27 prints an informational upgrade
warning to stderr before command parsing or AppKit hosting, including help,
version and background commands. `MacOSUpgradeNotice.emit` in
`provider-swift/Sources/darkbloom/MacOSUpgradeNotice.swift` names the local OS,
upcoming Darkbloom MDM deactivation, continued legacy verification during the
transition and the need to retain the profile until App Attest migration is
approved. The warning performs no network/config/profile operations and does
not change command execution, exit codes or stdout/JSON. macOS 27+ prints no
upgrade warning. It is independent of `DARKBLOOM_NO_UPDATE_CHECK`.

| Option | Type | Default | Effect | Source |
|---|---|---|---|---|
| `-c`, `--config <path>` | `String?` | `~/.config/darkbloom/provider.toml` | Provider TOML path. Accepted by the commands marked ✓ below | `provider-swift/Sources/darkbloom/Darkbloom.swift` (`ConfigOptions`); `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` (`defaultConfigPath`) |
| `--opencode`, `--hermes` | flag | — | With no subcommand, `darkbloom --opencode` is `darkbloom start --opencode` (likewise `--hermes`, or both): every other `start` option goes with it, in any order (`darkbloom --opencode --me-first`), and `start`'s errors and refusals apply. `start --opencode` keeps working; a subcommand keeps its own options (`darkbloom status --opencode` is refused). `darkbloom --help` shows both in one line each ([Set up OpenCode or Hermes](#set-up-opencode-or-hermes)) | `provider-swift/Sources/darkbloom/Darkbloom.swift` (`Darkbloom.expandingToolShortcuts`), applied by `main.swift` before it parses or hosts |
| `--version` | flag | — | Prints `ProviderCore.version` | `Darkbloom.configuration` |
| `-h`, `--help` | flag | — | Help; `darkbloom` with no subcommand prints help | `Darkbloom.run` |

Before most subcommands run, `runUpdateBannerIfEnabled`
(`provider-swift/Sources/darkbloom/Darkbloom.swift`) checks for a newer release
with a 2 s hard timeout and prints a one-line banner; `DARKBLOOM_NO_UPDATE_CHECK`
set to any value skips it. Logging goes to stderr so launchd captures it in
`~/.darkbloom/provider.log`.

In a terminal, `start`, `stop`, `restart`, `status` and `update` open with the
Darkbloom mark beside the command's name and show a one-row live line while
they wait (a drain, a restart, an update's download). It is look only: every
line they print is the same, in the same order. The live line, here and on the
cluster's screens, is always one row:
- It is fitted to the window's width at each redraw, minus 6 columns.
- Control characters in a reason become spaces, and a wide character counts as two columns.
- A long reason is shortened, keeping its time at the end.
- Line wrap is off while the row is drawn, so it is cut at the window's edge, never wrapped. The cluster setup's rules
apply (`DarkbloomCommandLook`, `provider-swift/Sources/ProviderCore/Terminal/DarkbloomCommandLook.swift`):
pipes, logs, the LaunchAgent's files, `NO_COLOR`, `CLICOLOR=0`, `TERM=dumb`, a
non-UTF-8 locale and windows under 40 columns get the plain bytes;
`DARKBLOOM_NO_ANIMATION` or `CI` keeps the mark and the line still. On a
paired Mac, `darkbloom start` opens the cluster's screen, which draws the mark
itself. A command that refuses before doing any work (an unreadable pairing
record, nothing to restart, flags that can't go together or an out-of-range
`--idle-timeout`, `update --rollback` as root), or finds nothing to do (`stop
--solo` with no single-Mac serving), prints only its lines, with no mark. The
mark appears once, at the top of the command you ran: `unenroll` and
`autopilot enable`/`models`, which run `stop --solo` and `start` inside
themselves, show none.

## Subcommands

Subcommands declared by `Darkbloom.configuration.subcommands`:

| Command | Purpose | `--config` | Source (`provider-swift/Sources/darkbloom/…`) |
|---|---|---|---|
| `cache` | Inspect or set encrypted-cache storage and daily write limits | ✓ | `Cache/CacheCommand.swift` (`Cache`) |
| `start` | Serve. Default: install and start the LaunchAgent; `--local` for Only me, with no coordinator. In a terminal, the first start asks how this Mac serves ([one question](#how-this-mac-serves-one-question)) | ✓ | `StartCommand.swift` (`Start`) |
| `schedule` | Edit, show or disable saved weekly availability and startup loading; never start/stop the service | ✓ | `Scheduling/ScheduleCommand.swift` (`AvailabilitySchedule`) |
| `switch` | Gracefully replace hosted models in the running coordinator-connected provider, without restart or reconnect | | `SwitchCommand.swift` (`Switch`) |
| `addon` | Debug add-on holds on the running provider: `status` (default), `hold`, `release` | | `AddonCommand.swift` (`Addon`) |
| `sandbox` | Set up and manage [Darkbloom Sandbox](./sandboxes.md) CI jobs through its add-on: status (bare), `setup`, `pause`, `resume`, `logs`, `uninstall`; `setup` requires an approval from the [Darkbloom Sandbox waitlist](#darkbloom-waitlist) | | `Sandbox/SandboxCommand.swift` (`Sandbox`) |
| `stop` | Drain accepted requests, then stop the LaunchAgent; `--uninstall` removes the provider, watchdog and desktop API agents and keeps every file | | `StopCommand.swift` (`Stop`) |
| `uninstall` | Take Darkbloom off this Mac: remove everything, or everything but the models ([below](#darkbloom-uninstall)) | | `UninstallCommand.swift` (`Uninstall`) |
| `restart` | Drain, restart with recorded configuration, and confirm fresh authorization | ✓ | `RestartCommand.swift` (`Restart`) |
| `status` | Config, hardware, schedule, live daemon state (including the coordinator's last `Trust: <level> / <status>` message), per-slot KV/MTP posture | ✓ | `StatusCommand.swift` (`Status`) |
| `doctor` | Diagnostics (see [troubleshooting](./troubleshooting.md#doctor-checks)) | ✓ | `DoctorCommand.swift` (`Doctor`) |
| `models` | `list`, `catalog`, `download`, `remove` | ✓ | `ModelsCommand.swift` (`Models`) |
| `local` | Print the local API's address and key | | `LocalCommand.swift` (`Local`) |
| `route` | Where your requests go when this Mac's local API can't take them: `this-mac`, `my-macs` or `my-macs-first` saves `[local] route` ([below](#darkbloom-route-this-mac-my-macs-my-macs-first)); `key` saves the account API key | ✓ | `RouteCommand.swift` (`Route`), `RouteChoiceCommand.swift` (`RouteChoiceFlow`) |
| `cluster` | Set up two Macs to serve one model together ([guided setup](./two-mac-cluster.md)); `cluster local` serves without a coordinator. In a terminal, the first setup asks how the pair serves (**Only me (this pair, local)**, **Darkbloom network**, or **Both, me first**, preselected: the leader's local API beside Darkbloom, which pauses while you use it), saves the answer in `[local] mode`, and asks nothing without a terminal ([Both, me first](./two-mac-cluster.md#both-me-first-the-pairs-own-api-beside-darkbloom)). Run again on a paired Mac it works like `darkbloom start` (which opens the same screen there): both Macs, the cable and the status, then the pair's models with the current one preselected (Enter keeps it or starts it again), each with the modes it runs there, the recommended one first and no speed, **Change how the pair serves** (the three choices below; `cluster local`'s list keeps its line to switch to Darkbloom), and **Start over**; another model asks once before the serving one stops, and every start ends with the outcome, the pair's card and `darkbloom stop` / `restart` / `status` ([after setup](./two-mac-cluster.md#the-steps-once)). It offers **Start over** after one question (also when the other Mac does not answer over the cable: the screen then names that Mac and what to run there), and **Pair again** without it only when the saved pairing was made with another Secure Enclave key; both take the steps of `cluster pair --forget` (`ClusterUnpairing`), then pair ([pairing again](./two-mac-cluster.md#pairing-again)) | ✓ | `ClusterCommand.swift` (`Cluster`) |
| `waitlist` | List the waitlists the coordinator offers and where the account stands (bare), or put the account on one and show where it stands (`waitlist cluster`, `waitlist sandbox`); waitlists are per account | ✓ | `Waitlist/WaitlistCommand.swift` (`Waitlist`) |
| `login` | Link the machine to an account (RFC 8628 device code) | ✓ | `LoginCommand.swift` (`Login`) |
| `logout` | Stop the provider, revoke its current saved token, then remove the local credential | ✓ | `LogoutCommand.swift` (`Logout`) |
| `benchmark` | Inference benchmarks and harnesses | ✓ | `BenchmarkCommand.swift` (`Benchmark`) |
| `update` | Self-update | ✓ | `UpdateCommand.swift` (`Update`) |
| `verify` | `doctor --strict` | ✓ | `VerifyCommand.swift` (`Verify`) |
| `enroll` | Show App Attest setup guidance or check frozen legacy eligibility before profile setup | ✓ | `EnrollCommand.swift` (`Enroll`) |
| `unenroll` | Choose full exit or MDM removal with App Attest | | `UnenrollCommand.swift` (`Unenroll`) |
| `logs` | Unified logs for subsystem `dev.darkbloom.provider` | | `LogsCommand.swift` (`Logs`) |
| `report` | Upload recent unified logs to the coordinator | ✓ | `ReportCommand.swift` (`Report`) |
| `autoupdate` | Toggle `provider.auto_update` | ✓ | `AutoUpdateCommand.swift` (`AutoUpdate`) |
| `beta` | `list`, `status`, `enable`, `disable` beta features | ✓ | `BetaCommand.swift` (`Beta`) |
| `idle` | Configure the saved idle-memory policy | ✓ | `IdleCommand.swift` (`Idle`) |
| `autopilot` | Experimental enrollment/status and residency policy; shadow by default | ✓ | `AutopilotCommand.swift` (`Autopilot`) |
| `fan` | Experimental fan control (`status`, `diagnose`, `enable`, `configure`, `disable`, `uninstall`) | | `Fan/FanCommand.swift` (`Fan`) |
| `watchdog` | Internal, hidden: crash-recovery watchdog process | ✓ | `WatchdogCommand.swift` (`Watchdog`) |
| `runtime-smoke` | Internal, hidden: load packaged Metal runtime and exit | | `RuntimeSmokeCommand.swift` (`RuntimeSmoke`) |

### `darkbloom start`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--coordinator-url <url>` | `String?` | `coordinator.url` (`wss://api.darkbloom.dev/ws/provider`) | Override the coordinator WebSocket URL |
| `--model <id>` | `[String]`, repeatable | `[]` | Select these startup models and skip the picker; compatible with Autopilot enrollment |
| `--all` | flag | `false` | Ordinary serving of every runtime-supported local model; skips the picker. Compatible with `--autopilot`, where only verified eligible downloaded network builds enroll |
| `--idle-timeout <mins>` | `UInt64?` | `backend.idle_timeout_mins` (`60`) | Override the idle unload timeout for this run |
| `--schedule` | flag | `false` | Open the interactive availability/loading wizard before background startup; rejects `--foreground` and Only me (`--local`) (`Start.run`, `StartCommand.swift`) |
| `--autopilot` | flag | `false` | Keep the normal startup selector, verify cached network inventory and save experimental enrollment; verification adds no downloads and the default rollout is shadow |
| `--no-autopilot` | flag | `false` | Save opt-out and retain ordinary idle-policy mode |
| `--foreground` / `--no-foreground` | flag, **hidden** | `false` | Serve in this process instead of installing the LaunchAgent; launchd passes it |
| `--local` | flag | `false` | Only me: [the local API](./direct-mode.md) with no coordinator, in this terminal; not saved in `[local] mode` |
| `--network` | flag | `false` | Darkbloom network: no local API (today's plain `start`); not saved in `[local] mode`, but the LaunchAgent keeps it until the next `start` |
| `--me-first` / `--no-me-first` | flag | unset | `--me-first`: Both, me first: a local API beside Darkbloom, and Darkbloom pauses while you use it; not saved in `[local] mode`, but the LaunchAgent keeps it until the next `start`. `--no-me-first`: Darkbloom keeps serving while you use the local API (saved as `[local] me_first = false`); `--me-first` undoes it |
| `--local-endpoint` | flag | `false` | Both, me first, the older flag: the local API beside Darkbloom, with me first on (Darkbloom requests pause while your local requests run and for `[local] me_first_idle_minutes` after) unless `--no-me-first` (`[local] me_first = false`); mutually exclusive with `--local` |
| `--me-first-idle <min>` | `UInt64?`, 1–120 | `[local] me_first_idle_minutes` (`2`) | Minutes with none of your requests before Darkbloom comes back; saved. Not `--idle-timeout` (model memory) |
| `--route <route>` | `this-mac`, `my-macs`, `my-macs-first` | `[local] route` | Where your requests go when this Mac can't take them ([the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router)); saved; needs an account key (`darkbloom route key`) |
| `--choose` | flag | `false` | In a terminal: ask how this Mac serves again, although a choice is saved |
| `--opencode`, `--hermes` | flag | `false` | Set OpenCode 2 or Hermes Agent up to use this Mac's local API ([below](#set-up-opencode-or-hermes)); not with `--network`, `--no-auth`, `--cluster-member`, `--distributed` or `--foreground` |
| `--port <n>` | `UInt16?` | `[local] port`, else the port this Mac's local API already uses, else the first free port from `8001`; saved the first time | This Mac's local API port, for every local API it serves; a port named here is used and saved ([below](#how-this-mac-serves-one-question)) |
| `--bind <addr>` | `String?` | `[local] bind`, else `127.0.0.1` | Local server bind address |
| `--no-auth` | flag | `false` | Disable the local bearer-token check |
| `--cluster-member` | flag | `false` | Register a control-only cluster member from the saved setup, in the foreground ([coordinator-paired member](../reference/configuration.md#coordinator-paired-member)). With `--local-endpoint --port <p> --bind <address>`, which the cluster service passes for Both, me first, the member that hosts the pair's slot also serves the pair's local API with the pair's key; any other member runs none. Refused with `--no-auth`, `--always-on` or `--supervise` |
| `--always-on` | flag | `false` | With `--cluster-member`: install the member as the provider LaunchAgent run by the supervisor ([always-on members](./cluster-always-on.md)) |
| `--supervise` | flag, **hidden** | `false` | With `--cluster-member`: run the supervisor in this process; launchd passes it for `--always-on` |
| `--distributed` | flag | `false` | With `--local`: serve the saved cluster setup as its rank 0 and register with the coordinator as a control-only member; the cluster service starts it |
| `--no-coordinator` | flag | `false` | With `--distributed`: never contact a coordinator; the cluster serves on the local API only (`ClusterLocalServing.leaderArguments`). Rejects `--coordinator-url`. [`darkbloom cluster local`](./two-mac-cluster.md#serving-locally-only) starts it this way |
| `--timeout <seconds>` | integer, 0–3600 | `600` | Drain a running provider before replacing its process/configuration |
| `--force` | flag | `false` | Explicitly permit cancellation if the old provider cannot drain |
| `--solo` | flag | `false` | On a Mac in a two-Mac cluster: start single-Mac serving on this Mac instead of the pair |

#### How this Mac serves: one question

A single-Mac `start` decides how this Mac serves (`StartServingResolver`,
`provider-swift/Sources/darkbloom/Start/StartLocalFirst.swift`; for users:
[Use your Mac yourself, first](./local-first.md)):

1. A mode flag: `--local`, `--network`, `--me-first` or `--local-endpoint`.
   It isn't saved in `[local] mode`, but the LaunchAgent this start installs
   keeps its arguments, so login, `restart`, updates and the watchdog serve
   that way until the next `start`.
2. `--choose` (a terminal only): the question again.
3. The saved choice, `[local] mode`, with or without a terminal. A saved
   `local` (Only me) serves in a terminal, so without one the start is refused
   before anything stops or starts (exit 64): ``This Mac is set to Only me,
   which serves in a terminal. Run `darkbloom start` in one, or name how to
   serve: --local, --network or --me-first.``
4. In a terminal (stdin and stdout), the question, after the terms notice and
   before the model picker:

   ```text
   How should this Mac serve?
     1. Only me, on this Mac      Darkbloom never contacts this Mac. Your tools use this Mac's own API.
     2. Darkbloom network         This Mac serves Darkbloom and earns while it runs.
     3. Both, me first            This Mac serves Darkbloom while you aren't using it. When you use it,
                                  Darkbloom traffic pauses until you've been idle for 2 minutes.
   Choose 1, 2 or 3 [3]:
   ```

   Enter takes the bracketed answer: the saved choice with `--choose`, else
   **Both, me first**. For 1 or 3 with an account key saved, a follow-up asks
   where your requests go when this Mac can't take them (`1. Only this Mac`,
   `2. Only my Macs (free)`, `3. My Macs first (the network answers when they
   can't; billed to your balance)`, `[2]`). The end of input, or three answers
   that aren't 1, 2 or 3, print `Cancelled: nothing was saved or started.` and
   exit 0.
5. Otherwise (no terminal, no saved choice: the LaunchAgent, the desktop app,
   scripts): today's behaviour, exactly. The Darkbloom network, no local port,
   no Keychain look-up, nothing written, and the same LaunchAgent arguments.

Only the question saves a mode. The answer, its follow-up and the local API's
port are written to `[local]` once the start goes ahead (after the model
picker; for "Only me", once its server listens), so a cancelled or refused
start saves nothing; "Only me" with `--schedule` or `--autopilot` is refused before
saving. **Only me** then serves in this terminal as `--local` does (Ctrl-C
drains it); **Darkbloom network** and **Both, me first** install the
LaunchAgent with the arguments `--local-endpoint` has always used
([configuration](../reference/configuration.md#local-first-use-local)).

- **One port per Mac** (`LocalAPIPort.choose`,
  `provider-swift/Sources/ProviderCore/Config/LocalAPIPort.swift`): every local
  API this Mac serves (the question's, a saved choice, `--me-first`, `--local`,
  `--local-endpoint`, the desktop app's starts) takes the same port, so the
  address the tools were given never moves:
  1. `--port <n>`: used as given, and saved when it isn't the saved port:
     ``Local API port: 8007 (saved, instead of 8005: tools set up for 8005 need
     `darkbloom --opencode` or `--hermes` again).``
  2. `[local] port`: used as it is, never probed or moved, even `8000` or a
     port another program holds (the local API then says why it isn't up).
  3. Otherwise the port this Mac's local API already uses: its running API's
     (`local.json`), else the one its installed LaunchAgent's job serves on (the
     job's `--port`, or the build's default for an app job without one,
     `LaunchAgent.installedLocalAPIPort`). It is kept as it is, even `8000`, and
     saved: a Mac updated from 0.10.10, whose local API serves on `8000`, keeps
     it, so the tools pointed there keep working. Said once:
     `Local API port: 8000 (saved; this Mac's local API already uses it).`
  4. Otherwise, on a Mac with no local API at all, one chosen now and saved: the
     first free port from the build's default (production's `8000`, so `8001`),
     up to 20 ports on, never `8000` (where other local AI apps listen) or
     `47420`–`47423` (pairs), which are never even probed. Said once:
     `Local API port: 8001 (saved; 8000 is left for other apps).` With none
     free, the start stops and says so.

  The `--foreground` service (launchd's child) never chooses or saves: its
  arguments carry the port. So does `start --local` that a service runs (an
  app job an older version wrote, or the cluster service's solo part,
  `Start.isServiceChild`). A saved port is kept whatever the mode; a mode flag
  still saves no mode.
- **A local API that can't listen:** Only me stops (exit 1):
  ``This Mac's local API couldn't listen on 127.0.0.1:8001: another program
  may use port 8001. Free it, or run `darkbloom start --port 8002`.`` Both, me
  first keeps serving Darkbloom, and `status` and `local` say why its local API
  isn't up ([`darkbloom status`](#darkbloom-status)). On a Mac in a two-Mac
  cluster, where `start` takes `--port` only with `--solo`, these lines name
  `darkbloom start --solo --port <n>` for single-Mac serving, and
  `darkbloom restart` for the pair's own API, whose port the pair picks
  (`LocalFirstWords.LocalAPIServer`).
- **Refused at parse (exit 64), before anything runs:** two different modes
  (`--local`, `--network`, `--me-first`/`--local-endpoint`), for example ``
  `--local` and `--me-first` choose different ways to serve. Use one: --local
  (only you, on this Mac), --network (the Darkbloom network) or --me-first (both,
  you first). ``; `--choose` with a mode flag; `--no-me-first` or
  `--me-first-idle` with `--local` or `--network`; `--no-me-first` with
  `--me-first-idle`; `--network` with `--route`, `--port`, `--bind` or
  `--no-auth`; `--me-first-idle` outside 1–120; `--choose`, `--route`,
  `--no-me-first` or `--me-first-idle` with `--foreground`. `--local` with
  `--local-endpoint` is still refused after the terms notice (exit 1).
  `--choose` without a terminal exits 64 and names the three flags.
- **No terminal, no model list:** no start asks a question without a terminal
  (stdin). One that names no models (`--model`, `--all`) for **Darkbloom
  network** or **Both, me first** would ask in the model picker, so it stops
  before anything is stopped or started, in one line on standard error (exit
  64): ``Without a terminal, `darkbloom start` can't ask which models to serve:
  add --model <id> (`darkbloom models list` shows this Mac's models) or
  --all.`` **Only me** serves the models already on this Mac and needs none.
  On a paired Mac, `start --solo` says it before this Mac's part of the pair
  is touched (`Start.requireModelsNamedWithoutTerminal`).
- **The summary** gains, with a local API:

  ```text
    Serving: Both, me first — Darkbloom pauses while you use this Mac, back after 2 idle minutes
    Local:   http://127.0.0.1:8001/v1 — your requests: this Mac first, then your other Macs (free)
             (`darkbloom local` shows the key)
  ```

  With `--no-auth` the local router passes nothing on, so the summary says
  `your requests: this Mac only` and `(no API key: --no-auth, so requests stay
  on this Mac)`, whatever the route, and the start doesn't ask the Keychain.
  No start screen prints the key, except `--local`'s own banner, as before. A
  start that nothing chose (step 5) prints today's summary.

#### Set up OpenCode or Hermes

`--opencode` and `--hermes`, usually run as `darkbloom --opencode` /
`darkbloom --hermes` ([global options](#global-options)), point the tools at
this Mac's local API with the config writers
([OpenCode and Hermes config writers](../architecture/tool-integrations.md);
`ToolIntegrationStep`, `provider-swift/Sources/darkbloom/ToolIntegration/ToolIntegrationStep.swift`).
They run once, at `start`:

1. **A local API already runs** (`local.json`, with a key, on the `--port` and
   `--bind` given, if any) and no option changes what serves (`--model`,
   `--all`, `--idle-timeout`, `--schedule`, `--autopilot`/`--no-autopilot`,
   `--coordinator-url`, `--choose`, `--no-me-first`, `--me-first-idle`,
   `--route`): nothing starts. `Darkbloom already serves on <host>:<port>;
   setting up OpenCode for it.`, then the tools (`Start.runningLocalAPI`). One
   without a key (`--no-auth`) is named instead, and nothing starts (exit 1):
   ``✗ Darkbloom's local API on :8001 has no key (--no-auth); tools need one:
   start it without --no-auth.``
2. **Otherwise `start` runs as above**, then: `--local` and Only me set the tools
   up beside the server once it is bound; a background start waits up to 30 s
   for its own local API (`Start.waitForLocalAPI`), and says at once when its
   `local.json` names a key that no key file holds; a paired Mac sets them up
   for a local API on this Mac after the pair starts, else says that
   `darkbloom cluster local` serves one. A start that would serve no local API
   (Darkbloom network: no terminal and no saved choice, or the answer 2) is
   refused before anything starts or is saved (exit 64), naming `--me-first`
   and `--local`.
3. **Each tool:** found on `PATH`, else in `~/.opencode/bin` or `~/.local/bin`
   (`ToolLocator`), never installed; `opencode --version` below 2 is refused,
   and a Hermes older than v0.20.2 (`hermes --version`) is set up with one
   `Warning:` line, as it can't read the key yet (`HermesVersion.keyCommandWarning`).
   The endpoint's `GET /v1/models` (15 s, `ToolIntegrationStep.modelListTimeout`:
   well over the router's own wait for the coordinator's lists, which an
   unreachable coordinator runs out) and the catalog (5 s) give the models;
   `ToolIntegration.configure` writes the block with a backup. Without the
   catalog (offline, or a model it doesn't list), a model the tool's file
   already lists keeps that entry's name, image input, reasoning and limits
   (`IntegrationModel.keeping`), so a re-run changes nothing and says the catalog
   wasn't reachable; a model new to the file gets its ID and text input only, and
   one line says to run the start again online for names and image support.
   The result block names the file changed, the backup and a one-line undo,
   then `Requests:` (where your requests go) and
   `Other tools:` (`OPENAI_BASE_URL` and `OPENAI_API_KEY="$(cat <key file>)"`).
   No line or file holds the key, and the `--local` banner shows no key when a
   tool flag is given (`Start.bannerShowsKey`); its `Your requests:` line and the
   tool block come from one Keychain read. A model of this Mac's that isn't loaded
   yet has no context in `/v1/models`, so one line says to run the start again
   once it is loaded, to pick up its limits.

A tool it can't set up prints `✗` and why, writes nothing and ends with
`Darkbloom keeps serving.`; the start then exits 1 (a background start keeps
running; `--local` keeps serving in the terminal). They are not single-Mac
options: on a paired Mac they apply to the pair's local API.

On a Mac in a two-Mac cluster (one that holds a pairing; a cluster service left
without one is a leftover, which `darkbloom cluster status` names), `start` starts the pair, as `darkbloom cluster` does
(`Start.pairStart`, `ClusterPairCommands`), whatever its state: running, stopped with `darkbloom stop`, or not running
here (its other Mac gone). It first says so in one line
(`This Mac is in a two-Mac cluster with the other Mac (…): starting the pair.`):

- In a terminal it opens exactly the screen `darkbloom cluster` shows on this
  Mac (`ClusterPairCommands.openScreen`), whose title names this Mac's part:
  "Darkbloom cluster · Leading Mac" or "Darkbloom cluster · Joining Mac".
  In a color terminal each finished step folds to one line, and the run's whole
  flow goes to `~/.darkbloom/cluster-setup/screens/` ("Full log: …" at the end);
  see [Two Macs as one provider](two-mac-cluster.md).
- Without a terminal (scripts) it starts the pair's saved model on both Macs
  (on the Mac that follows, through the leading Mac), waits up to 10 minutes
  until it serves or says why not, and ends with a result block shaped like
  single-Mac start's. While it waits it says so (`Waiting until the pair serves
  (up to 10 min).`), and a status that stays the same is said again once a
  minute (`Still waiting (up to 10 min in all): …`). The exit status is `darkbloom cluster status`'s (`0`
  serving, `3` not serving yet, `4` stopped, `5` the other Mac isn't
  answering); `1` when no model was chosen yet (`run darkbloom start in a
  terminal to choose one`) or the cluster can't be reached.

```text
This Mac is in a two-Mac cluster with the other Mac (Apple M5 Max, 128 GB): starting the pair.
✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).
  Model:   Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%
  Macs:    this Mac (Mac Studio) leads · the other Mac (Apple M5 Max, 128 GB) follows
  Serves:  through Darkbloom

  darkbloom stop     Stop both Macs
  darkbloom restart  Restart with the current model
  darkbloom status   Check status
```

`--solo` starts single-Mac serving on this Mac instead: it is the one way to
serve this Mac alone on a paired Mac. Single-Mac serving and this Mac's part of
the pair take the same serving lock, so `start --solo` while the pair runs here
is refused (stop the pair first). Single-Mac options such as `--model` and
`autopilot enable`'s need `--solo` too: without it nothing starts, and they are
named (exit 64, below). The desktop app's **Start serving** is the exception
(`Start.appStartOptions`): it runs `start --model <id> [--local-endpoint]
--config <path>` with no terminal, and has no `--solo`, so on a paired Mac it
starts the pair as a plain `start` does, never this Mac alone. The pair serves
its own model and its own way. When the app named another model, the start ends
with one line the app shows: ``This Mac serves in a pair: started the pair with <the pair's model>; `darkbloom cluster` changes its model.``
(`ClusterPairSummary.appStartModelLine`, after a start that serves or is
loading).

While the pair doesn't run here (`ClusterPairWatch`: stopped, or its other Mac
hasn't answered for 15 minutes, or it never served in its first 15 minutes),
`start --solo` serves this Mac alone (`Start.PairStart.serveAlone`). How this Mac
would serve alone is checked first: with **Only me** saved (by `darkbloom
start`, or by `darkbloom cluster` for the pair) and no mode flag, a start
without a terminal is refused in one line, as on one Mac (exit 64), before
anything here is stopped or cleared. A pair that is merely stopped gives one
line: ``This Mac is in a two-Mac cluster with the other Mac (…), which is
stopped: serving this Mac alone (`darkbloom start` starts the pair again).``
So does a started pair while this Mac's cluster service is down, as ``… which
isn't running here: serving this Mac alone (…)``: nothing asked the other Mac,
so it never says the other Mac isn't answering.
A started pair's part still running here is stopped first, and the pair's saved
start on this Mac is cleared (`ClusterService.releaseForSingleMac`, up to 5
minutes, after up to 10 for a cluster command that is running). It says
``This Mac is in a two-Mac cluster with the other Mac (…), which isn't running
here: stopping this Mac's leftover part and clearing its saved start
(`darkbloom start` starts the pair again).`` before, and ``This Mac's leftover
part of the pair stopped, and its saved start is cleared: serving this Mac
alone.`` only once that is done (`Start.releaseLeftoverPartToServeAlone`). A
part that doesn't stop in time starts nothing (exit 1) and names `darkbloom
cluster pair --status`, then `darkbloom cluster pair --forget <pin>`, then
`darkbloom start` (no longer paired). While a cluster command is running it
first says ``Waiting for the pair's running command to finish (up to 10
minutes; ^C stops waiting and leaves the pair as it is).``; one still running
after 10 minutes starts nothing (exit 1) and says ``The pair's command was
still running after 10 minutes, so nothing was stopped or started. Try again,
or run `darkbloom cluster` to see what's running.`` `stop`, `restart` and
`update` say the same when they stop a leftover part; `restart` and `update`,
which then serve this Mac alone, say the cleared line only once it is true too.
See [going back to serving on one Mac](two-mac-cluster.md#going-back-to-serving-on-one-mac). The
cluster's own starts (`--cluster-member`, `--distributed`, the cluster
service's solo part) and launchd's `--foreground` child are never redirected,
and a replacement drains only the provider service's process, never the
cluster's part (`ServiceDrain.soloProviderState`).

On a paired Mac, `darkbloom start` says first when it replaces a cluster service
running from a terminal session with the login agent. When macOS's Local Network
setting keeps this Mac's link follower off the cable, it ends its wait at once
with where to turn it on (System Settings → Privacy & Security → Local Network →
"Darkbloom", the row macOS lists for the DevNet app too; with no such row, Allow
on macOS's prompt on that Mac's screen at the next dial; through Screen Sharing
on a Mac with no display), and exits 1.

Options on a paired Mac (`Start.singleMacOptions`, `ClusterPairSummary.singleMacOptionsRefusal`):

| Options | Without `--solo` on a paired Mac |
|---|---|
| `--config` | Applies to the pair (its cluster service settings) |
| `--model`, `--all`, `--idle-timeout`, `--schedule`, `--autopilot`/`--no-autopilot`, `--coordinator-url`, `--timeout`, `--force`, `--local-endpoint`, `--network`, `--me-first`/`--no-me-first`, `--me-first-idle`, `--route`, `--choose`, `--port`, `--bind`, `--no-auth` | Refused by name in every state of the pair, nothing starts, exit 64: ``This Mac is in a two-Mac cluster with the other Mac (…): `--model` is for single-Mac serving, so nothing was started.`` then ``To choose the pair's model, run `darkbloom start` in a terminal; to serve this Mac alone with it, add --solo.`` Without a terminal, `--model` and `--local-endpoint` alone (the app's Start) start the pair instead, as above. With `--solo` they serve this Mac alone while the pair doesn't run here, as above |
| `--local` | Refused the same way, plus ``To serve the pair on the leading Mac's own API only: `darkbloom cluster local`.`` (also said for `--local-endpoint`) |
| `--cluster-member`, `--distributed`, `--foreground` | The cluster's own starts and launchd's child: never redirected to the pair |
| `--always-on`, `--supervise`, `--no-coordinator` | Valid only with `--cluster-member` or `--distributed` (refused at parse otherwise) |

A Mac whose pairing record can't be read is never taken for "not in a cluster"
(as `ClusterService.holdsNoPairing`): `start`, `stop` and `restart` change
nothing without `--solo` (`cluster stop`: without `--service` or
`--local-only`), and say why (`ClusterPairSummary.membership`):

```text
This Mac's pairing record couldn't be read (pairings.json is malformed; nothing is trusted from it), so it may be in a two-Mac cluster.
Single-Mac serving next to a cluster would compete for this Mac's memory. To serve on this Mac alone, run `darkbloom cluster` on this Mac to check the pairing first, or pass --solo.
```

Exit 1 (`ExitCode.failure`) when `--local` and `--local-endpoint` are combined,
a debugger is attached, RAM is below 8 GB, Metal is unavailable, hardware
detection fails, no model is selected, or the local server does not bind within
5 s (`StartCommand+Preflight.swift`, `StartCommand+Modes.swift`).
A selection that would serve GLM-5.3-Flash below the macOS GPU wired-memory
limits prints a `warning:` with the fix and continues
([GLM-5.3-Flash GPU wired-memory limit](#glm-53-flash-gpu-wired-memory-limit)).

The ordinary catalog picker uses the selected models' shared activation reserve
when checking each model's load estimate. Adding an unmeasured model can raise
that reserve: the TUI refuses a toggle that would invalidate an existing choice,
and numbered input validates the complete requested set. `all` first excludes
models that cannot fit alone, then filters the remaining rows under their shared
reserve. Total selected weights may exceed the budget because models can take
turns. These are nominal estimates; [live admission](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#shared-host-memory-admission)
still applies the configured reserve and current available memory. A resolved
Autopilot opt-in retains the conservative flat picker reserve used by its separate
inventory check (`Start.PickerReserveMode`, `Start.resolveFallbackSelection` in
`provider-swift/Sources/darkbloom/Start/StartCommand+Picker.swift`).

Autopilot inventory verification names each cached model before checking its bytes.
If another process holds that model’s update/verification lock, the check reports
the busy model immediately. An ordinary start with saved consent then fails before
changing enrollment or draining the running provider; retry after the update finishes.
`status` and `autopilot status` read the same daemon snapshot, including nested
Autopilot residents and load history. Enrollment does not make a live daemon disappear
from status. `autopilot status` prints `Adopted (serving outside the selection)` for
models an operation adopted and `Held: <model> until <UTC> (<time> left)` for each
placement hold (`provider-swift/Sources/darkbloom/Autopilot/AutopilotStatusCommand.swift`).

A replacement start, with or without Autopilot, completes the picker/preflight and saves the selected IDs
under `backend.enabled_models` while holding the lifecycle lease, before it
disables recovery or drains/stops the current provider. Failure of this initial
selection write leaves the current service unchanged. Autopilot additionally
verifies cached inventory before persistence or drain; selected startup models
must be in that verified inventory. Enrollment itself preserves other preferences. After drain acknowledgement,
Autopilot consent is saved before stopping the daemon and installing the chosen
configuration. If this later write fails, a gracefully drained daemon is left
running and drained, with recovery disabled; correct the configuration and retry
`start`. No replacement is installed (`Start.completeDaemonReplacement`). Foreground/local starts also require a drained handoff;
the process-lifetime kernel lock never silently sends SIGKILL after a short grace period.
On ordinary non-enrolled launchd-managed foreground starts (including restart and watchdog recovery),
an explicitly pinned `enabled_models` takes precedence over old `--model` plist
arguments. A directly invoked foreground `--model` still overrides config
(`Start.usesPinnedModelSelection`, `Start.launchDaemon`).

The config sidecar lock spans persistence and synchronous drain setup. If
disabling recovery or publishing the request fails, the exact previous TOML
bytes (or original file absence) are restored, including whether the model key
was pinned. Restoration failures are reported. Once publication succeeds, a
later drain timeout retains the replacement intent; no config lock is held while
waiting (`ProviderModelSelection.withReplacement`,
`provider-swift/Sources/ProviderCore/Service/ProviderModelSelection.swift`).
Missing custom files are seeded from this invocation's resolved configuration,
not from the separate canonical config file.

After a successful provider `bootout`, the lifecycle waits for `launchctl print`
to confirm that the exact service label is absent before replacing its plist or
bootstrapping it. It polls at 100 ms intervals with a 10-second monotonic budget
and at most 101 probes. Unknown or permission errors fail the operation; an
unconfirmed removal leaves replacement unstarted. This also applies to stop,
uninstall and restart after drain. The budget includes returning probe calls;
the shared launchctl subprocess has no command timeout, so a hung subprocess
can exceed that wall time. Bootstrap error 37 (operation in progress) is a
failure, not confirmation that the replacement started.
Source: `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`
(`unloadService`, `waitForServiceRemoval`, `loadService`).

`start --schedule` requires interactive stdin and stdout. Its confirmed draft
stays in memory until model selection succeeds; cancellation or an empty/failed
selection does not save the schedule or replace the running service
(`Start.run`, `Start.launchDaemon` in
`provider-swift/Sources/darkbloom/Start/StartCommand+Daemon.swift`). Ordinary `start`
does not add a schedule prompt; it uses saved settings. Saved availability also
controls Both, me first (`--me-first`, `--local-endpoint`), but Only me (`--local`) ignores it.

### `darkbloom schedule`

| Flag | Type | Default | Effect | Source |
|---|---|---|---|---|
| No flags | interactive editor | saved settings | Edit weekly availability and startup loading; requires interactive stdin/stdout | `provider-swift/Sources/darkbloom/Scheduling/ScheduleCommand.swift` (`AvailabilitySchedule.run`, `requireInteractiveTerminal`) |
| `--show` | flag | `false` | Read saved settings and local time zone, not live daemon state; no edits | Same file (`AvailabilitySchedule.run`) |
| `--disable` | flag | `false` | Disable scheduling while retaining windows and preload policy; mutually exclusive with `--show` | Same file (`AvailabilitySchedule.disabled`, `validate`) |
| `-c`, `--config <path>` | `String?` | default provider TOML path | Read/write this configuration; use the same path when starting it | Same file (`AvailabilitySchedule.configOptions`, `run`) |

The wizard offers these modes in `provider-swift/Sources/darkbloom/Scheduling/ScheduleWizard.swift`
(`ScheduleWizard.run`):

| Mode | Saved availability |
|---|---|
| Use saved windows | Re-enable existing windows; requires a saved window |
| Always available / disable scheduling | Serve whenever the provider runs; retain existing windows |
| Overnight | Mon-Fri starts, `22:00` to `08:00` the following day |
| Weekends | Full Saturday and Sunday, `00:00` to `00:00` the following day |
| Custom weekly windows | Start from saved windows and add, edit or remove windows |

Enabled modes open the add/edit/remove editor before confirmation. Days accept
comma-separated names, `weekdays`, `weekends`, `daily`, or ranges such as
`fri-mon`; days identify the window's start day. Enter keeps the displayed
default; `q`, `cancel`, EOF or declining confirmation discards the draft
(`ScheduleWizard.editWindows`, `editWindow`, `parseDays`, `ask`).

The loading choice edits only [`backend.startup_preload`](../reference/configuration.md#startup-model-preload):
preload at startup/window opening, or skip preload and load on demand. Coordinator
load commands can still load models in on-demand mode. The editor preserves
`backend.preload_models`, `backend.enabled_models` and `backend.idle_timeout_mins`
(`ScheduleSettings.apply`, `save` in
`provider-swift/Sources/darkbloom/Scheduling/ScheduleSettings.swift`). It reloads
under the config lock and refuses to overwrite concurrent schedule/preload edits.

`schedule` never starts or stops the provider. Saved edits apply on the next
start/restart, not live; use `darkbloom restart` for a running provider. The Mac
must stay awake. See [availability configuration](../reference/configuration.md#provider-availability)
and [calendar/window semantics](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#provider-availability-windows).

### `darkbloom switch`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--model <id>` | `[String]`, repeatable | `[]` | Replace the complete hosted selection with these local IDs; any invalid ID rejects the whole selection |
| `--all` | flag | `false` | Select all eligible local models; mutually exclusive with `--model` |
| `--timeout <seconds>` | integer, 0–3600 | `600` | Graceful drain deadline; `0` refuses unfinished work immediately but still acknowledges an already-settled drain |

With neither selection flag, this command reuses the `start` catalog picker and
downloader. It checks fresh daemon identity and switch capability before opening
the picker, and uses the running daemon's runtime capabilities rather than
initializing a second inference runtime. There is no `--force` or `--config`:
the daemon's own resolved config path, including a custom path, is authoritative,
and the command scans local models in that config's `model_cache_directory`.

The provider validates local artifacts before fencing new coordinator and
local API admissions, finishes accepted requests and terminal usage, and
asks the coordinator to validate the complete selection before unloading anything.
It then replaces its full model inventory on the existing coordinator session.
It does not restart the process, reconnect, re-attest, install a service, or
change watchdog/login recovery settings. Coordinator URL, authentication and
local API settings remain unchanged. Selected resident models can stay
loaded; new models load on demand under the existing memory safeguards.
The coordinator must support `models_replace`; deploy the coordinator upgrade
before enabling this command on providers. Unsupported or missing receipts fail
closed rather than forcing a reconnect.

With `--timeout 0`, an already-idle provider still waits up to 30 seconds for the
coordinator's terminal barrier; zero never skips usage settlement. Nonzero
deadlines retain their full drain-and-barrier budget. Artifact validation occurs
before this deadline and can be preempted by stop/restart or OS shutdown; a late
hash result cannot change provider state. Each switch request is atomically
consumed, so a later scheduled window in the same process cannot replay it.
Sources: `provider-swift/Sources/ProviderCore/ProviderLoop+ModelSwitch.swift`
(`drainForModelSwitch`, `cancelModelSwitchAndWait`),
`provider-swift/Sources/ProviderCore/Service/LifecycleMailbox.swift` (`claimSwitchRequest`).

Validation carries each snapshot's pre-hash fingerprint into the live model
state. Where load policy permits hash reuse, unchanged snapshots avoid a second
full weight read; metadata changes and mandatory fresh/SSD checks still rehash.
Rollback restores the previous hash/fingerprint pair
(`ProviderModelSwitchValidation`,
`provider-swift/Sources/ProviderCore/Service/ProviderModelSwitchValidation.swift`).

Eligible local off-catalog models can remain in the selection for owner-only
inference, just as at registration. They do not become publicly routable; tracked
models still need their pinned catalog hashes and required runtime capabilities
([coordinator/registry/provider_models_replace.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/registry/provider_models_replace.go), `ReplaceProviderModels`).

Success requires a matching completion receipt from the running provider, not
just mailbox publication. The provider requires a matching
`models_replace_resumed` receipt from the coordinator before writing that
completion receipt. A successful selection is persisted for later restart,
watchdog recovery and scheduled serving windows. Stale/missing/older daemons and
Only me (`--local`) servers fail without launching anything. A drain timeout returns failure and
leaves admission closed while accepted work continues; retry `switch` after
the outstanding work finishes. Rejected selections are not partially applied.
Live rollback restores an originally absent model key/file when no other edit
intervened. Concurrent unrelated config changes are retained; a newer model
selection is never silently overwritten. An unavailable completion receipt is
reported as unconfirmed, never success, and coordinator routing stays fenced
when the committing `models_replace_ack` cannot be written. If the final
`models_replace_resumed` receipt is lost, routing may already have resumed;
`switch` reports the outcome as unconfirmed.
`status` displays the latest switch outcome, request ID, unfinished-request count,
message and selection; stale daemon snapshots are explicitly marked
(`Status.printDaemonStatus` in `provider-swift/Sources/darkbloom/StatusCommand.swift`).
Sources: `provider-swift/Sources/darkbloom/SwitchCommand.swift` (`Switch`),
`provider-swift/Sources/ProviderCore/Service/ProviderModelSelection.swift`
(`ProviderModelSelection.stageReplacement`, `ProviderModelSelection.restore`).
After provider readiness, the coordinator refreshes desired alias builds
for the current inventory; the provider preserves snapshots received during the
commit wait. It restores prefetching before sending readiness, so the refreshed
snapshot can converge even if it arrives before the routing receipt.
The provider publishes refreshed capacity immediately after reopening local
admission; the ready frame names that heartbeat's `capacity_seq`. The coordinator
waits for the matching sequence and ready frame before routing queued work.

Scheduled serving keeps the initial foreground selection, including manual
`--model` overrides, until a live switch or a change to `backend.enabled_models`
on disk. Each later window reads that selection from the same resolved config path.
It also reads the full current `backend.model_autopilot` settings and consent.
Disabling Autopilot between windows restores ordinary saved `enabled_models`
selection even when that list has not changed; an enrolled window uses its
current recorded inventory instead of stale startup consent.
An empty saved list selects all eligible local models found for that window;
explicit IDs select only those models. The provider validates and hashes the
result before reopening; an invalid selection fails instead of reverting to
startup models. The scheduled loop keeps the original window end while hashing
and skips startup if that window has closed. A late start serves only for the
remaining window time. Other provider settings outside model selection and
Autopilot settings, runtime
identity/capabilities and local API options remain frozen for the process
(`ScheduledWindowSelection` in `provider-swift/Sources/darkbloom/ScheduledWindowSelection.swift`;
`Start.runScheduled` in `provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift`).


### Graceful stop and restart

```bash
darkbloom stop --timeout 600
darkbloom restart --timeout 600 --startup-timeout 180
darkbloom stop --force             # explicit interruption, including stalled work
```

Use the [stop flags](#darkbloom-stop) and [restart flags](#darkbloom-restart) below
for deadline recovery. Commands do not initiate graceful shutdown by killing the
serve task. `SIGTERM`, `SIGINT` and AppKit termination enter the same drain;
Only me (`--local`) also waits for active HTTP response bodies. `SIGHUP`
enters it too for a provider started by hand (`start --local`, or
`start --foreground` typed into a terminal), so closing its terminal window
drains it instead of ending the process at once. `SIGHUP` is not a stop signal
in two cases: the provider's launchd job does not take it, so it has whatever
action launchd started the job with, and a start that arrived with `SIGHUP`
ignored, for example under `nohup`, keeps ignoring it. A provider that
re-executes itself in place for a self-update (one that is not the provider
LaunchAgent's own job; launchd relaunches that job) carries the same choice
into the new process (`ProviderStopSignals` in
`provider-swift/Sources/ProviderCore/Service/ProviderStopSignals.swift`). The signal
deadline is configurable with
[`DARKBLOOM_DRAIN_TIMEOUT_SECONDS`](../reference/configuration.md#provider-drain-deadline).
Once local HTTP admission closes, new POST requests receive HTTP 503 with the
OpenAI JSON error message `Provider capacity is temporarily unavailable.` and
the usual CORS header. Health reads and OPTIONS preflights remain available;
already admitted response bodies retain their drain ownership.
Signal-only shutdown disarms current watchdog recovery but preserves configured
login startup; use `darkbloom stop` for a persistent stop.
During distributed startup, `SIGTERM` and `SIGINT` are latched before the serving
task is attached. Closing the startup signal owner restores each signal’s prior
handler, flags and blocked-signal mask, including when one signal was already
ignored. Repeated close calls leave later signal changes alone.
Source: `provider-swift/Sources/darkbloom/DistributedStartSignals.swift`.
With no accepted work left, a graceful drain retries native MiMo owner
retirement until the owners retire or its deadline passes: after served
requests, the first attempt only starts joining their finished consumers
(`provider-swift/Sources/ProviderCore/ProviderLoop+Lifecycle.swift`,
`performLifecycleDrain`). A drain completes without the coordinator
acknowledgement only when no work is left and the provider has no registered
coordinator session, for example while it is reconnecting; the command then
reports the acknowledgement as `not needed (no coordinator connection)`. A
registered session must acknowledge before the deadline.
Newly installed or CLI-restarted jobs have launchd `ExitTimeOut = 3660`; an
existing job must be restarted to load that allowance. OS logout/shutdown may
impose its own limit. Crashes, power loss, SIGKILL and explicit force can interrupt
responses. The [protocol barrier](../reference/protocol-messages.md#provider-lifecycle-drain)
requires the updated coordinator before normal provider shutdown can be confirmed.

### `darkbloom status`

Only `--config`. Read-only. Prints the daemon snapshot (refresh cadence under
[Runtime constants](#runtime-constants)) and the last trust message the
coordinator sent; what the levels mean is in
[`architecture/security/attestation.md#trust-levels`](../architecture/security/attestation.md#trust-levels),
and how to read the line in [attestation → Verify](./attestation.md#verify).

Beside the add-on hold line, a running provider's `Serving:` line says how
this Mac serves, read from its state and `local.json` (`Status.servingLines`,
`provider-swift/Sources/darkbloom/StatusCommand+LocalFirst.swift`):

| State | Line |
|---|---|
| Darkbloom network | `Serving: Darkbloom network only — this Mac has no local API` |
| Both, its local API couldn't listen (`DaemonState.localAPIFailure`) | ``Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (`darkbloom start --port 8002`)``; with no port free, ``(free it, or name another with `darkbloom start --port <n>`)``; for another failure, ``it couldn't listen on 100.64.0.9:8001 (Can't assign requested address); `darkbloom restart` tries again``. On a Mac in a two-Mac cluster: ``(`darkbloom start --solo --port 8002`)`` and `` `darkbloom restart --solo` tries again`` for single-Mac serving; for the pair's API, written by the cluster's part, ``(`darkbloom restart` starts the pair's API on a free port)``, or ``(free it, then `darkbloom restart`)`` with no port free (`LocalFirstWords.whyNotUp`) |
| Both, me first, open | `Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)` |
| Both, me first, paused | `Serving: you first — Darkbloom paused since 14:02 (your last request 1 minute ago; back at about 14:13 if you stay idle)`; while your requests run, `(your request is running; back 2 minutes after it ends)`; then, only while some finish, `         2 Darkbloom requests are finishing` |
| Both, me first off | `Serving: Darkbloom and you, shared — Darkbloom keeps serving while you use this Mac (me first is off)` |
| Only me (`--local`) | `Serving: only you, on this Mac — Darkbloom never contacts this Mac` |

With a local API it adds where your requests go and whether an account key is
saved, never the key: `Your requests: this Mac first, then your other Macs
(free) · account key saved`, or ``Your requests: this Mac only · no account key
(`darkbloom route key` saves one)``. Only then is the Keychain asked. A local
API without a key (`--no-auth`) passes nothing on: `Your requests: this Mac
only · no local key (--no-auth), so nothing is passed on`, without asking the
Keychain.

### `darkbloom doctor`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--strict` | flag | `false` | Exit 1 on any WARN as well as FAIL |
| `--coordinator <url>` | `String?` | config URL | Coordinator for the network checks |
| `--support` | flag | `false` | Append coordinator URL, token presence, MDM state, PID-file path |
| `--clear-backend-guard` | flag | `false` | Delete `~/.darkbloom/kv-backend-guard.json`, reset the crash-loop counter in `watchdog-state.json`, exit |
| `--hardware` | flag | `false` | Print the desktop hardware-load document (topology, one sample, counter capabilities) as JSON, exit |

Clearing restores model-aware `auto` on the next model load, not guaranteed
paged service. It preserves explicit settings, the kill switch and capability
vetoes (`provider-swift/Sources/darkbloom/DoctorCommand.swift`,
`runClearBackendGuard`). See
[guard recovery](./troubleshooting.md#kv-backend-crash-loop-guard).

Exit 1 when any detailed check or diagnosis line is FAIL (or WARN with
`--strict`). On macOS 27 or later the diagnosis includes an `APP ATTEST`
section. It shows the daemon's local key state and launch session, and the
diagnostics from the provider's last `ready`: how the process started, how the
previous one exited, SIP and authenticated root, signing preflight, key history,
the last native Apple error chain and APNs push history. The section also
reads local `devicecheckd` log evidence; macOS lets only administrator accounts read the system log.
The check names are listed in [troubleshooting](./troubleshooting.md#doctor-checks).
[`app-attest-shadow.md`](../reference/app-attest-shadow.md) defines the fields.

### `darkbloom verify`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--coordinator <url>` | `String?` | config URL | Coordinator for the network checks |

Same checks as `doctor`; any WARN or FAIL exits 1.

### `darkbloom models`

| Subcommand | Flag / positional | Type | Default | Effect |
|---|---|---|---|---|
| `list` | `--json` | flag | `false` | Raw output |
| `list` | `--all` | flag | `false` | Include models filtered out by `backend.enabled_models` |
| `list` | `--hash <model-id>` | `String?` | `nil` | Compute the aggregate SHA-256 of one model |
| `catalog` | `--coordinator <url>` | `String?` | config URL | Catalog source |
| `catalog` | `--json` | flag | `false` | Raw output |
| `catalog` | `--type <t>` | `String?` | `nil` | Filter by `model_type` (e.g. `text`) |
| `download` | `<modelID>` | `String` | — | Catalog id (or S3 name) |
| `download` | `--coordinator <url>` | `String?` | config URL | Resolve the catalog entry |
| `download` | `--r2-cdn <url>` | `String?` | `DARKBLOOM_R2_CDN_URL`, else the build default `https://models.darkbloom.ai` (`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`, `resolveCDNURL`) | Mirror base URL |
| `remove` | `<modelID>` | `String` | — | Model to delete from the effective model cache |
| `remove` | `--force` | flag | `false` | Skip confirmation |
| `location` | `[PATH]` | `String?` | status/menu | Select an existing readable, writable cache directory; interactive changes require `yes` |
| `location` | `--check` | flag | `false` | Inspect PATH, or the effective cache, without changing config or weights |
| `location` | `--from-env` | flag | `false` | Explicitly import the current Hugging Face environment cache once and save its absolute path |
| `location` | `--reset` | flag | `false` | Clear the saved location and restore the legacy home cache, regardless of ambient variables |

All model subcommands accept `--config <path>`. Location behavior is implemented
by `Models.Location` in `provider-swift/Sources/darkbloom/ModelsLocationCommand.swift`;
cache precedence is specified in [model cache configuration](../reference/configuration.md#model-cache-location).

### `darkbloom local`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--json` | flag | `false` | Print the raw `~/.darkbloom/local.json` record |

Exit 1 (and `{}` in JSON mode) when no live local server is recorded
(`LocalEndpoint.readLiveInfo`, `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift`);
it then names both ways to start one, `start --me-first` (Darkbloom and you,
you first) and `start --local` (only you, on this Mac). When the running
provider's local API couldn't listen (`DaemonState.localAPIFailure`), it says
why instead: ``The local API isn't up: port 8001 is in use (`darkbloom start
--port 8002`).`` (`Local.notUpLine`), with the commands `status` names on a Mac
in a two-Mac cluster.
A server bound to `0.0.0.0` or `::` also prints a `network:` line with this
Mac's Bonjour (`.local`) URL (`Local.networkURL`). When the running provider
serves that endpoint, two lines follow `pid:`: `serving:` (how it serves, in
the start summary's words) and `requests:` (where your requests go)
(`Local.servingLines`). A server without a key says `requests: this Mac only
(…)` under its API key line instead, and only `serving:` follows `pid:`. A
keyed server adds `tools:    darkbloom --opencode · --hermes` (`Local.toolsLine`). `--json`
is unchanged.

### `darkbloom route this-mac`, `my-macs`, `my-macs-first`

| Command | Saves | A request this Mac can't take |
|---|---|---|
| `darkbloom route this-mac` | `[local] route = "this-mac"` | Gets this Mac's own answer; nothing is passed on. Needs no account key |
| `darkbloom route my-macs` | `[local] route = "my-macs"` | Goes on to your other Macs, free; never to the Darkbloom network |
| `darkbloom route my-macs-first` | `[local] route = "my-macs-first"` | Goes on to your other Macs (free), then to the Darkbloom network, billed to your balance |

Each takes `-c`, `--config` (the `provider.toml` to save in) and writes only
`[local] route` (`setLocalSettings`), so it replaces a hand edit of the file
and `darkbloom start --route`. It then says what the route means; with
`my-macs-first`, that requests from other machines (your LAN or tailnet) never
use the paid network ([the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router)).
The same choice again writes nothing (`✓ Already saved. …`).

- **Without a saved account key,** `my-macs` and `my-macs-first` save nothing
  and exit 1: ``✗ Not saved: `darkbloom route my-macs` passes your requests on
  with your account API key, and this Mac has none saved.``, then the command
  that saves one (`darkbloom route key`) and the one to run again. It only asks
  whether a key is saved, and never prints one.
- **A local API running now uses it from its next request,** with no restart
  and no model reload: `✓ Saved. Your local API uses it now.` With none
  running: `✓ Saved. It applies when your local API starts.` Its router reads
  `[local] route` again when `provider.toml` changes
  ([the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router)).
  One without a local key (`--no-auth`) keeps every request on this Mac,
  whatever the route, and the command says so.
- **In a two-Mac cluster,** the leading Mac's route applies: the pair's local
  API runs there and passes on what the pair can't take, including requests
  the other Mac forwards to it. On the leading Mac the command says so; on the
  other Mac it saves the route for when that Mac serves alone (``It applies
  when this Mac serves alone (`darkbloom start --solo`).``) and names the
  command to run on the leading Mac.
- A `provider.toml` that doesn't load is refused with its reason, and nothing
  is written (exit 1).

`RouteChoiceFlow` in `provider-swift/Sources/darkbloom/RouteChoiceCommand.swift`.

### `darkbloom route key`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--stdin` | flag | `false` | Read the account API key from standard input (its first line) instead of hidden input at the terminal |
| `--remove` | flag | `false` | Remove the saved key; requests then stay on this Mac |
| `-c`, `--config` | path | the default config | The `provider.toml` whose `[coordinator] url` checks the key and whose `[local] route` the summary names |

`--stdin` and `--remove` can't be combined. The key is refused before any
check when it is empty, has spaces, line breaks or non-ASCII characters, is
over 512 characters, or is this Mac's local key (`dk-local-…`)
(`LocalRouterAccountKeyFormat`). It is then checked once with
`GET /v1/models` and `X-Darkbloom-Route: self`: a `401` or `403` saves nothing
and exits 1; an unreachable coordinator saves it with a note. It is kept in the
Keychain (service `<keychain prefix>.route`, account `account-api-key`; the
data-protection Keychain in signed builds, the login keychain otherwise) and
never printed (`RouteKeyFlow`, `provider-swift/Sources/darkbloom/RouteCommand.swift`;
`KeychainLocalRouterAccountKeyStore`). After it saves or removes the key, it
posts the Darwin notification `<keychain prefix>.route-key-changed`: a running
local API keeps the key in memory and reads it again on its next request that
needs it, so it says `Your local API uses it now.` (or, with none running, `It
applies when your local API starts.`). A key removed while the route passes
requests on says what the next request does: ``Your local API uses it now.
From its next request, one this Mac can't take gets this Mac's own answer
instead of going to your other Macs or the Darkbloom network.`` On the Mac that
follows in a two-Mac cluster, it says that the pair's local API passes requests
on with the leading Mac's key, and to run `darkbloom route key` there. When the
local API running now has no local key (`--no-auth`), it says that this API
keeps every request on this Mac and never uses the key. ^C at the hidden prompt gives the terminal its echo
back before the command ends (`HiddenReadSignals`). See
[the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router).

### Cluster placement request metadata

The native helper accepts
`darkbloom-cluster-plan request-scope --model-dir DIR --prompt-tokens N --output-tokens N`
and prints JSON with the registered family limits and conservative charge for
that request. It reads metadata only. `plan --model-dir` and the provider's
placement flow obtain this quote automatically when either requested axis
exceeds the layout reference. A saved `--layout` without an exact quote retains
its original limits. Sources: `ClusterPlacementTool.run` in
`libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Placement/ClusterPlacementTool.swift`
and `ClusterPlacementFlow.run` in
`provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementFlow+Run.swift`.

Without `--link LINK.json`, `darkbloom-cluster-plan plan` prices the link of two
devices as setup does: from the probes saved for that pair in owner-only
`~/.darkbloom/cluster/link-probes.json` (the median of the pair's last eight
loads within 30 days), or from `--link-probes FILE`. The two device labels must
be the pair's member IDs. The plan's first lines say which probes were used, or
why none were (no file, no probe for the pair, a file others can read), and the
plan is then unmeasured. A named file without the pair stops the command. The
tensor-parallel section prints the reductions' cost per decode step in ms or µs.
Each device's tensor-parallel share steps come from owner-only
`~/.darkbloom/cluster/share-probes.json` the same way (each Mac's newest timing
per share of this model within 30 days, by member ID), or from
`--share-probes FILE`; the plan's first lines name the shares used, and without
any every share is predicted as before. A named file that is not a share probe
history stops the command.

### `darkbloom cluster gpu-limit`

```bash
darkbloom cluster gpu-limit [--undo]
```

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--undo` | flag | `false` | Remove the job that keeps the limit raised and return `iogpu.wired_limit_mb` to the macOS default |

Lets this Mac's GPU keep its memory less 16 GiB resident, so GLM-5.3-Flash runs
on two 128 GB Macs with room for long requests (Apple silicon Macs with 128 GB
or more only; exit 2 elsewhere, with the reason, and where the Mac does not
report the limits). It prints the current and the new limit, asks once (`y`), and
then macOS asks an administrator to approve. Where the limits are already met,
it installs the boot job that keeps them if that job is missing or differs, and
changes nothing if it is in place. It needs a terminal; without one it prints
the commands an administrator can run and exits 2. Values, persistence and
undo: [GPU memory limit for a GLM pair](../reference/configuration.md#gpu-memory-limit-for-a-glm-pair)
(`provider-swift/Sources/darkbloom/ClusterGPULimitCommand.swift`).

### `darkbloom cluster local`

The setup response check uses the model's default reasoning controls. It does not send a binary thinking override; if its token budget ends during reasoning, it reports that the model is still thinking. This is a liveness check, not an answer-quality benchmark. Source: `provider-swift/Sources/ProviderCore/Inference/Distributed/Console/ClusterSetupProbeRequest.swift` and `ClusterSetupWizardLiveOperations.prompt`.

```bash
darkbloom cluster local [<model>] [--bind <address>]
```

| Argument / flag | Type | Default | Effect |
|---|---|---|---|
| `<model>` | `String?` | none | Choose this model (its id or listed name, any case) without the list |
| `--bind <address>` | `String?` | `0.0.0.0` (`ClusterServingScope.localOnlyDefaultBind`) | Where the leader's API listens: `localhost` or a numeric IPv4/IPv6 address (`ClusterServingScope.isValidBind`) |
| `--model-dir`, `--worker` | `String?`, **hidden** | none | As for `darkbloom cluster` (developer) |
| `--private-glm-image-qualification` | flag, **hidden** | `false` | Select the bounded GLM image candidate on the current paired leader for local qualification; requires the exact cached GLM artifact, uses automatic placement, and does not grant coordinator or solo serving |

Runs the onboarding asking for Only me (`ClusterOnboardingRequest`),
saved in the leader's setup record (`ClusterOnboardingLeadership.localOnly`,
`localBind`) until **Change how the pair serves** in `darkbloom cluster`'s list (or
**Switch to serving through Darkbloom** in this command's own list) serves through Darkbloom again. It asks
nothing and saves nothing in `[local]`.
The leader part then starts with `--no-coordinator`. Needs a terminal; exit 1
otherwise. On the Mac that joins a waiting leader it pairs, says to continue on
the leader with `darkbloom cluster local` (`ClusterOnboardingDriver.joinedLocalLine`) and, like
`darkbloom cluster`, follows the start there to its ✓ (exit 0) or ✗ (exit 1); q leaves (exit 0). Steps: [Only me: the pair for you alone](./two-mac-cluster.md#serving-locally-only)
(`provider-swift/Sources/darkbloom/ClusterLocalCommand.swift`).

### `darkbloom cluster status`

Says whether the cluster serves now, and if not, why and what to do. Nothing is
started or changed; on the Mac that follows, the leading Mac is asked over the
cable. The state and reasons are the status lines `darkbloom cluster` shows
(`ClusterOnboardingNotServing`), read as the other Mac's window reads them.

The commands these messages name are this build's own: the DevNet app's `status`, `stop`,
`start` and `restart` say `darkbloom-dev …`, never the production `darkbloom`.

```bash
darkbloom cluster status [--json] [--details] [--config <path>]
```

```text
Cluster: this Mac (Mac Studio) leads · the other Mac (Apple M5 Max, 128 GB) follows
Model: Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%
Serves: through Darkbloom
✗ Not serving: The other Mac (Apple M5 Max, 128 GB) isn't verified by Apple yet; Darkbloom retries by itself at about 00:34. Don't restart either Mac until then.
Next: Leave both Macs running: Darkbloom retries by itself. Or serve locally only: `darkbloom cluster local` on this Mac.
```

| Exit status | `state` | Meaning |
|---|---|---|
| `0` | `serving` | The pair serves: through Darkbloom once the coordinator has it, or on the leading Mac's local API when it serves Only me |
| `3` | `loading`, `not_serving`, `unknown` | Not serving yet: loading, or a reason in `reason` (such as macOS keeping a Mac off the local network, or a pair not offered to Darkbloom, below). A load whose part keeps ending gives that end as its reason, as the start's screen says it: "this Mac's part ended (exit 1: deadline) and starts again by itself" |
| `4` | `stopped` | Stopped (Stop in `darkbloom cluster`, or `darkbloom cluster stop`), also while the other Mac isn't answering |
| `5` | `other_mac_away` | The pair is started and the other Mac isn't answering over the cable (its cluster service is off, it sleeps, or waits for a login) |
| `6` | `not_paired` | This Mac isn't in a cluster |
| `7` | `pairing_unreadable` | This Mac's pairing record couldn't be read, so it may be in a cluster; `reason` says why when known |

While macOS's Local Network setting keeps a Mac's link follower off the cable, both Macs read `not_serving` (exit 3)
by the setup screens' rule and in their words (`ClusterLocalNetworkAccess.statusWords`), instead of a load that never
ends. The DevNet app names "Darkbloom Dev" and `darkbloom-dev`, and says that macOS lists it as "Darkbloom"
(`ClusterService.localNetworkRow`: both apps share one bundle ID).
- On the Mac that is kept off (its own cluster service's refusal), `reason` is "This Mac can't reach the other Mac over
  the cable: macOS keeps Darkbloom off the local network" and `next` is "On this Mac: System Settings → Privacy &
  Security → Local Network → turn on “Darkbloom”; if it isn't listed, click Allow when macOS asks on this Mac's
  screen, the next time Darkbloom dials over the cable (on a Mac with no display, through Screen Sharing); then run
  `darkbloom start` here, or choose Retry in `darkbloom cluster` on the other Mac."
- On the leading Mac, from about 20 seconds into its part (the ✗'s rule; it then asks the other Mac's status), and
  then steadily while the other Mac stays refused, also while its part ends on the missing link and starts again,
  `reason` is "The other Mac can't reach this Mac over the cable: macOS keeps Darkbloom there off the local network"
  and `next` names that Mac: "The other Mac (Apple M5 Max, 128 GB): System Settings → Privacy & Security → Local
  Network → turn on “Darkbloom”; if it isn't listed, click Allow when macOS asks on that Mac's screen, the next time
  Darkbloom dials over the cable (on a Mac with no display, through Screen Sharing). Then run `darkbloom start` here,
  or choose Retry in `darkbloom cluster`." Once the setting is on, it clears when that Mac's follower gets through.
- On both Macs, `lines` then holds that state's line, "Not serving: <reason>.", as the plain output's ✗ line does.

A pair set to serve through Darkbloom that serves on the leading Mac's local API has no cluster approval attached, so
the coordinator can't form it and it earns nothing. Both Macs read `not_serving` (exit 3), never `serving` or "earning
through Darkbloom" (`OnboardingLive.notOfferedLines`):
- `reason` is `not offered to Darkbloom (<why>)`: the leading Mac's latest approval check (for example `this Mac's
  check refused it: Unequal tensor-parallel shares serve local clusters only …`), `no cluster approval is attached to
  its setup`, or `the coordinator could not be reached or has no cluster support`.
- `lines` add where it answers meanwhile: `Meanwhile it answers only on the local API at http://localhost:<port> (no
  Darkbloom traffic).`
- The plain output says `Serves: through Darkbloom (not offered)`; `serves` stays `darkbloom`, the way it is set to
  serve.
- `next` is "To offer it to Darkbloom: `darkbloom cluster` on <the leading Mac>, then choose the model again (it is
  planned for Darkbloom). Or serve locally only: `darkbloom cluster local` on <the leading Mac>."
- `darkbloom start` without a terminal stops waiting at once on this reason (exit 3).

A pair that serves Both, me first says `Serves: through Darkbloom, and on its local API with you first`, and, before
`Next:`, on the Mac whose part runs rank 0 (`ClusterPairSummary.localAPILines`):
- whether Darkbloom is paused for you, in `status`'s words for one Mac with `Pair:` (`Pair: you first — Darkbloom
  paused since 14:02 (…)`, `Pair: Darkbloom and you, me first — open to Darkbloom (…)`, or `Pair: Darkbloom and you,
  shared — …` with `[local] me_first = false`), and `N Darkbloom requests are finishing` under it;
- `Local API: http://127.0.0.1:<port>/v1 on this Mac` (with `, and port <port> of its LAN or tailnet address` on
  every interface), never the key (`darkbloom local` shows it), or `Local API: not listening yet` while the part
  starts;
- `Members: the other Mac (…) is part of the pair; it runs no local API`.
On the other Mac: `Local API: on the other Mac (…), which runs the pair's API; `darkbloom status` there says whether
Darkbloom is paused for you` and `Members: this Mac is part of the pair; it runs no local API`. `--json` is unchanged
(`serves` stays `darkbloom`).

While single-Mac serving runs on either Mac of a started pair, the pair can't start there and it doesn't stop by
itself. Both Macs read `not_serving` (exit 3), never "keep trying by themselves":
- `reason` is "The pair can't start: a single-Mac Darkbloom provider (process <N>) is serving on <Mac>, and the pair
  can't share a Mac with it".
- `next` is "Single-Mac serving doesn't stop by itself: run `darkbloom stop --solo` on each Mac named, then
  `darkbloom start` on either Mac. Or `darkbloom cluster` on <the leading Mac> offers to stop it and start the pair."
- `darkbloom start` without a terminal stops waiting at once on this reason (exit 3).

During a model or mode change, or while the pair updates Darkbloom, `status` and `cluster status` can read `stopped`
(exit 4) or `unknown` for a minute or two while the pair is actually reloading. If such a change happened recently,
or the status showed "Updating…", wait about a minute and check again before acting. Run `darkbloom start` only if it
still reads `stopped`.

A stopped pair reads `stopped` (exit 4) even while the other Mac isn't answering, as after a stop the other Mac asked
for before it left (its uninstall does): `lines` are "Stopped; last model …" and "The other Mac (…) isn't answering
over the cable.", with `other_mac.answers` `false`.

When the pairing record can't be read, the plain output is the reason and what
to do, and `--json` gives `paired`, `role`, `other_mac`, `model` and `serves` as
`null`:

```text
This Mac's pairing record couldn't be read (pairings.json is malformed; nothing is trusted from it), so it may be in a two-Mac cluster.
Next: Run `darkbloom cluster` on this Mac to check it.
```

`--json` prints one object with the same exit status. Schema 1; every key is
present, `null` when unknown; keys are only ever added
(`ClusterPairSummary.JSON`):

| Key | Type | Value |
|---|---|---|
| `schema` | integer | `1` |
| `paired` | bool? | This Mac holds a pairing (a leftover cluster service without one is `false`); `null` when its pairing record couldn't be read |
| `role` | string? | `leader` or `member` |
| `this_mac` | string? | This Mac's own name (System Settings) |
| `other_mac` | object? | `name` (its hardware, as pairing showed it), `answers`: on the Mac that follows, whether the leading Mac answered; on the leading Mac, `true` while both run the cluster (or confirm its leader), `false` while the other Mac is away, `null` when not known |
| `model` | object? | `id`, `name` (catalog name, `null` when none) |
| `mode` | string? | `tensor parallel`, `pipeline`, `pipeline with speculative decoding`, … (`ClusterOnboardingDeployment.modeWords`), from the deployment line the leading Mac recorded at the start, whatever the model's name; without one, the mode the ✓ line marks (`tensor parallel` or `pipeline`). The plain output's `Model:` line shows it |
| `split` | string? | Each Mac's share, such as `M3 Ultra 40 layers / M5 Ultra 24 layers` (pipeline) or `M3 Ultra 50% / M5 Max 50%` (tensor parallel), from the same deployment line; `null` without one |
| `serves` | string? | `darkbloom` or `local` |
| `state` | string | `serving`, `loading`, `not_serving`, `stopped`, `other_mac_away`, `not_paired`, `unknown`, `pairing_unreadable` |
| `reason` | string? | Why it does not serve, in the screens' words |
| `next` | string? | What to do, in commands |
| `lines` | [string] | The status lines `darkbloom cluster` shows |
| `service` | object | `running`, `starts_at_login` (this Mac's cluster service) |
| `exit_code` | integer | The exit status above |

On the Mac that follows, the status lines are the leading Mac's answer over the
cable. `cluster status` and `status` wait at most 10 seconds for it: after 3
seconds they say `Waiting for the leading Mac's answer (up to 10 s).`, and past
10 seconds they show this Mac's own view (`The leading Mac didn't answer in
10 s; this is this Mac's own view.`), with `other_mac.answers` `null`. With
`--json` these lines go to standard error (`ClusterPairSummary.boundedStatus`).

`--details` prints the saved setup and the leading Mac's session for support, as
earlier versions printed by default; with `--json`, that report. It prints
`MTP: on (decode verifies drafts of the model's own speculative head)` when the
saved setup decodes with a head (the speculative pipeline, Qwen3.8 27B's
resident assistant, GLM-5.3-Flash in tensor parallel), otherwise
`MTP off: <reason>`. Code: `provider-swift/Sources/darkbloom/ClusterDiagnosticsCommand.swift`
(`Cluster.Status`), `provider-swift/Sources/darkbloom/ClusterPairSummary.swift`
(`ClusterPairSummary`).

### `darkbloom cluster stop` and `darkbloom cluster link --remove`

| Command | On a Mac in a cluster |
|---|---|
| `darkbloom cluster stop` | The same as `darkbloom stop` on a paired Mac: stops the pair on both Macs, which stay stopped after a restart while both cluster services stay up, idle (`Cluster.Stop.mode`). `--service` also stops this Mac's cluster service and keeps it from starting at login, the earlier `cluster stop`: on the Mac that follows a started cluster it asks the leading Mac to stop both Macs first (`This Mac follows the other Mac (…), which leads: \`darkbloom cluster stop\` stops the cluster on both Macs.`, `Cluster.Stop.pairStop`). `--local-only` stops only this Mac's service, without asking the other Mac |
| `darkbloom cluster link --remove` | Says first that it undoes the cable port setup that works now and that the cluster stops serving on both Macs until `darkbloom cluster` (or `link --fix`) sets it up again, then asks `Remove it? [y/N]`. `--yes` (`-y`) removes without asking; without a terminal, or with `--json`, it needs `--yes` (exit 1, nothing changed). When the other app on this Mac (the production Darkbloom or Darkbloom Dev) still holds the port in its link record (`ClusterLinkRepair.otherInstallsUsingCable`, read only), it also says `<app> on this Mac also uses this cable port for its own pair: …` and asks at a terminal even with `--yes`; without a terminal, or with `--json`, it refuses (exit 1, nothing changed): `--yes` doesn't answer for the other app. `--dry-run` never asks (`Cluster.Link.removalGate`). Without `--device` it undoes every port Darkbloom set up under one macOS approval, naming them (`Thunderbolt ports en2, en1 and en6`); `--device` undoes that one (`ClusterLinkRepair.removeIsolation`). Each port's service goes before the port goes back in its bridge (a port's only service through `scutil --prefs`, which `networksetup` refuses to remove), and the approval stops at the first command that fails: the message then says the commands after it did not run and which ports are still to undo (`--json`: `remaining`), exit 4 |

`darkbloom cluster --help` ends with these commands and what each is for
(`Cluster.commandList`).

Provider-local Chat Completions, Completions and Responses reject negative output
token limits with HTTP 400 before model invocation or streaming headers. Explicit
zero, positive and omitted limits retain their existing semantics. This local
SDK validation does not change coordinator normalization or model numerics
(`libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/OpenAIRequestValidation.swift`,
`OpenAIRequestValidation.preparedRequest`).

### `darkbloom login` / `darkbloom logout`

`login` takes `--config` only and runs `performDeviceCodeLogin`
(`provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift`): `POST
/v1/device/code`, print URL and code, poll `POST /v1/device/token`, write
`~/.darkbloom/auth_token`. It also records the successful token response's issuer
in owner-only `auth_token.issuer.json`, bound to a hash of that token. The provider
token is not a consumer API key. A failed save removes newly written credential
files so login can be retried instead of leaving a partial local login.

`logout` uses `Logout.run` in `provider-swift/Sources/darkbloom/LogoutCommand.swift`
and `ProviderLogout.perform` in `provider-swift/Sources/ProviderCore/Auth/ProviderLogout.swift`:

| Flag | Type | Default | Effect / source |
|---|---|---|---|
| `--config <path>` | path | Global config default | Accepted for CLI compatibility; never overrides the saved token's issuer (`Logout.configOptions`) |
| `--timeout <seconds>` | integer, 0-3600 | `600` | Wait for accepted work and the coordinator drain acknowledgement (`ServiceDrain.swift`, `DrainOptions`) |
| `--force` | flag | `false` | Explicitly permit interruption of unfinished work; process exit must still be confirmed (`DrainOptions`, `Logout.requireExited`) |

The command disables watchdog/login recovery, drains and stops the provider,
confirms the captured process identities have exited, and acquires the
single-instance lock. It holds that lock and the lifecycle/update lease through
revocation and local token deletion, preventing start/recovery from reusing the
credential in between. A missing token file does not skip process shutdown.
Unconfirmed exit, lock failure or a normal drain timeout refuses logout without
removing the credential; a published drain remains closed with recovery disabled.

After shutdown, it sends the current saved token **itself**, not its hash, as
`Authorization: Bearer <token>` to `POST /v1/device/revoke` at its recorded issuer.
Changed configuration or a different running provider cannot retarget that
credential. Legacy credentials without matching issuer metadata are removed
locally with remote revocation explicitly unconfirmed; no URL is guessed.
Unreadable or malformed configuration does not prevent local logout.
`ProviderLogout.revokeToken` uses a ten-second request/resource
timeout, follows no redirects, and confirms remote revocation only for HTTP
`204`. Offline errors, cancellation, unsupported endpoints and every other status
leave remote invalidation unconfirmed but still permit local deletion. Output
distinguishes confirmed revocation, local-only logout with a warning, and no
saved credential. Tokens and response bodies are not logged. This requires a
matching platform endpoint; local completion does not establish remote support.
The request URL keeps the original coordinator's host and port while changing
only the WebSocket scheme and endpoint path; path text cannot become an authority.

This revokes only the current token, not every machine/account credential. It
does not remove App Attest/SE keys, model downloads or management profiles.
Automatic restart stays disabled until `darkbloom start`; link again with
`darkbloom login` when needed. The backend contract belongs in the sibling
[platform API reference](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/api-contracts.md),
not this repository; consult the platform's latest default branch for current
backend behavior. Immutable source links elsewhere are evidence snapshots.

### `darkbloom benchmark`

The throughput sweep installs the same `MLXMemoryGuard` allocator limits as
serving before it loads weights. Its progress log separates active allocations,
reusable cache bytes and the active-allocation peak at each decode cell and
shutdown (`provider-swift/Sources/ProviderBenchmark/ThroughputSweep.swift`,
`run` and `runDecodeBatch`). These counters are not OS process footprint.

| Group | Flags (type = default) |
|---|---|
| Throughput | `--model <id>` (`String?`), `--prompt <text>` (`ModelBenchmark.defaultPrompt`), `--iterations <n>` (`ModelBenchmark.defaultIterations`), `--max-tokens <n>` (`ModelBenchmark.defaultMaxTokens`) |
| Ordinary token scores | `--teacher-forced-input <json>` (`String?`, unset), explicit `--model <id>` and `--kv-backend contiguous\|paged` (`BenchmarkCommand.swift`, `teacherForcedOptionError`) |
| Runtime generation | `--runtime-generation`, optional `--runtime-prompt-file <utf8>`, `--runtime-prompt-date YYYY-MM-DD`, `--runtime-mtp`, `--runtime-assistant-directory <path>`, `--runtime-concurrency <sizes>`, `--runtime-stagger`; production slot output and memory as JSON, prefix cache off (`RuntimeGenerationBenchmark`; `provider-swift/Sources/ProviderBenchmark/RuntimeConcurrencyBenchmark.swift`, `RuntimeConcurrencyBenchmark`) |
| Live KV precision | `--kv-quantization balanced\|k8v4\|k8v8\|native`; overrides live config/environment for production benchmark engines; default resolves to native. Use `--runtime-generation`, teacher forcing, sweep or scheduler modes to exercise serving KV. Ordinary scalar `MLX.generate` benchmarks do not measure this representation. MiMo stays native. |
| Checkpoint KV precision | `--kv-checkpoint-quantization balanced\|k8v4\|k8v8\|native`; independently overrides checkpoint config/environment; default requests balanced. Applies only to eligible complete stores and never forces the live backend. Cache-disabled modes do not measure checkpoint writes or restores. |
| Scheduler prefill decision | `--scheduler-prefill-decision`, `--expected-model-aggregate-sha256`, `--expected-registered-binary-sha256`, `--expected-version`, `--source-sha`, `--decision-iterations` (`SchedulerPrefillDecisionReport.minimumLiveIterations`), `--output <path>` (`BenchmarkCommand+SchedulerPrefillDecision.swift`) |
| Sweep | `--sweep`, `--prefill-lengths` (`"128,512,2048"`), `--max-batch` (`6`), `--batch-sizes` (`String?`), `--decode-tokens`, `--decode-prompt-tokens`, `--decode-iterations` (`ThroughputSweep` defaults), `--kv-backend` (`"auto"`) (`BenchmarkCommand+Sweep.swift`) |
| Scheduler prefill | `--scheduler-prefill`, `--prefill-iterations` (`2`), `--prefill-fixed-prompt` (`false`; scheduler-prefill only) (`BenchmarkCommand.swift`, `BenchmarkCommand+Sweep.swift`) |
| Arrival invariance | `--arrival-invariance`, `--arrival-width` (`4`, range `1...16`), `--arrival-prompt-tokens` (`512`), `--arrival-prompt-lengths` (`String?`; exactly one integer ≥2 per row, overrides uniform length), `--arrival-decode-tokens` (`64`), `--arrival-iterations` (`3`) (`BenchmarkCommand.swift`, `Benchmark.arrivalPromptLengths`); requested width alone is not measured forward-width evidence |
| Backend parity | `--parity`, `--assistant-model <id>` (`String?`), `--parity-max-tokens` (`48`), `--parity-prefix-tokens` (`28672`) (`BenchmarkCommand+Parity.swift`) |
| Prompt preparation | `--prompt-prep`, `--prompt-prep-lengths` (`"2048,8192,32768"`), `--iterations`; CPU only, loads only the tokenizer, times uncached, first-sighting, next-turn and repeated prompt preparation and the body decode for chat, agent and tool-loop conversations with the prompt token cache's background comparisons off, prints JSON and exits 2 on any token-ID or decoded-field difference (`provider-swift/Sources/ProviderBenchmark/PromptPreparationBenchmark.swift`) |

Scheduler prefill defaults to rotating the seed tokens by `iteration * 17` for
measured iterations; both bootstrap and full-context warmups use offset `0`.
`--prefill-fixed-prompt` keeps offset `0` for every request, repeating identical
input tokens at each prompt length for sustained repeated-input measurements.
It preserves fresh engines, disabled prefix caching, chunk policy and timing.
The JSON report records `promptMode` (`"rotating"` or `"fixed"`),
`warmupPromptOffset`, and each sample's `promptOffset` before wrapping by the
seed length. These optional fields extend schema `4`; absent metadata in older
reports remains unspecified. The flag is rejected outside `--scheduler-prefill`
before runtime loading (`provider-swift/Sources/ProviderBenchmark/SchedulerPrefillBenchmark.swift`,
`run`, `makePrompt`, `SchedulerPrefillBenchmarkReport`). Schema `5` adds
`prefillChunkTokens` and `maxBatchedTokensPerStep`; with
`soloPrefillStripeTokens` they record the scheduler the production build handed
the warm-up engine, after serving, calibration and GLM policy
(`EngineV2Factory.ProductionBuild.prefillGeometry`), and a measured engine built
with different geometry fails the run.

Scheduler prefill installs `MLXMemoryGuard.configureOnce` before loading weights,
matching serving and the throughput sweep. Stderr records the selected allocator
limits and effective cache limit. Earlier scheduler-prefill runs omitted this
setup; account for that difference when comparing saved results. This does not
change memory reserves or establish wired weight residency.

Ordinary DiffusionGemma generation uses its production native block engine and
honors `--kv-quantization`. Its `NATIVE_BLOCK_BENCHMARK` records include resolved
precision, prepared prompt tokens/date, generated text/tokens and observed cache
memory. Runtime generation emits one autoregressive request; it does not use
`--iterations`. Cache capacity peaks sample the host before submission and on
delta/terminal events, so they do not capture every prefill transient.

With balanced live quantization, `--kv-backend auto` requires paged storage.
Missing required sweep cells return a nonzero exit status for balanced, `k8v4`
and `k8v8`, including `auto`. Scheduler-prefill lengths must exceed one token;
its producer and arrival invariance already reject incomplete measurements.
With `--kv-quantization native`, auto uses the
[exact qualified-artifact allowlist](../architecture/prefix-cache.md#kv-layouts)
and retains its observable contiguous fallback.
Explicit `--kv-backend paged` refuses construction failures rather than measuring
a fallback; kill-switch and capability/span-mask vetoes require native precision
to serve contiguous. Inspect the measured engine's `resolvedKVBackend` and report
`kvBackend` block (`provider-swift/Sources/darkbloom/BenchmarkCommand.swift`,
`Benchmark.kvBackend`). The
[five-artifact rollout](https://github.com/Layr-Labs/d-inference/blob/4230fa03ddbc84e34e2de150c89431744d6f1c55/docs/design/release-090-paged-qwen-cache.md) is **not yet
validated**; benchmark selection alone is not release evidence.

Environment inputs for the harnesses are in
[`reference/configuration.md`](../reference/configuration.md).
[Model verification I/O](../reference/configuration.md#model-verification-io)
uses reusable-buffer reads and up to four independent file readers by default,
retaining complete integrity checks. It affects load/verification work, not
ordinary resident decode; explicit overrides provide the original serial path.
For a pinned GPT-OSS matrix with aggregate B=2/B=4 decode, raw token timing,
and mixed prompt arrivals, see [the profiling workflow](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/test.md#6-scripts-and-release-integrity).

### `darkbloom update`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--coordinator <url>` | `String?` | config URL | Release source |
| `--check-only` | flag | `false` | Report; do not install |
| `--override-quarantine` | flag | `false` | Reinstall a quarantined version: one that failed 3 starts, or one rolled back with `--rollback` |
| `--rollback` | flag | `false` | Restore the release kept for rollback (the retained predecessor) and quarantine the installed release. Contacts no coordinator |
| `--yes`, `-y` | flag | `false` | With `--rollback`: do not ask for confirmation. Required when standard input is not a terminal |
| `--timeout <seconds>` | integer, 0–3600 | `600` | Drain the running service before activating the installed update or the rollback |
| `--force` | flag | `false` | Explicitly permit interruption during update or rollback activation |

Exit 1 on `quarantined`, `busy`, `cancelled`, `downloadFailed`, `hashMismatch`,
`replaceFailed`, or a failed check (`UpdateResult`, `provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`).

`--rollback` cannot be combined with `--check-only`, `--override-quarantine` or
`--coordinator`, and `--yes` applies only to it. It prints the plan (installed
version, restored version, the install generation it records) and asks
`Roll back to vX? [y/N]`. A loaded provider is drained, the layout is swapped
through the watchdog's journaled rollback under the update lease, and the
provider is restarted and the watchdog rearmed, as for an installed update; a
stopped provider, or one stopped while the prompt was open, is only swapped
(`provider-swift/Sources/darkbloom/UpdateRollback.swift`, `UpdateRollback`;
`provider-swift/Sources/ProviderCore/Update/SelfUpdater+Rollback.swift`,
`rollbackPlan`, `rollBackToPredecessor`). The prompt runs without a lock, so
the command decides every check again once it holds the update lease, before
the drain, and again at the swap for what the drain could let change. Over the
swap it holds the cluster service lock, so no cluster service starts, and the
provider instance lock (or leaves it with the drained service process), so no
other provider starts. A pair's coordinated update holds the same lease from
its check through its install, and its cluster service login agent stays
loaded through its restart, so a rollback and a pair update never interleave.
It runs only as the user the provider runs as, not as root. It exits 1 and
changes nothing when
this Mac serves in a `darkbloom cluster` pair (a running cluster service, a
loaded cluster service login agent, or a loaded cluster-member provider job), a
provider runs outside launchd (`darkbloom start --foreground`, also when it
replaced the service while the prompt was open) or started after the plan was
shown, the installed release changed after the plan was shown, another update
or recovery holds the lease,
no release is kept for rollback, the installed release is already that
release, the installed `Darkbloom.app` is not the recorded release, or the kept
release fails its hash or signature check (`RollbackRefusal`). On a
`darkbloom cluster` Mac whose app an install outside the updater changed, the
cluster service removed the kept release at its next start, so no release is
kept until the next update
([an install outside the updater](./cluster-always-on.md#an-install-outside-the-updater)). A refusal at
the swap, after the drain, restarts the drained provider on the installed
release; when another provider took the instance lock during the drain, it is
not signalled and the service stays drained. On a `darkbloom cluster` Mac,
stop its cluster service first; once it runs again, the other Mac follows the
rollback to the same release
([a rollback on one Mac](./cluster-always-on.md#a-rollback-on-one-mac)). Steps are in
[installation → Roll back to the previous release](./installation.md#roll-back-to-the-previous-release).
See [installation → Update](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/provider/installation.md).

### `darkbloom enroll` / `darkbloom unenroll`

`EnrollmentService.enroll` in `provider-swift/Sources/ProviderCore/Auth/Enrollment.swift`
returns App Attest setup guidance on macOS 27 or later before checking profiles,
contacting the enrollment endpoint or opening Settings. This guidance asks the
operator to verify current status; it is not an App Attest grant. Older macOS
uses the legacy profile flow only for eligible frozen identities. The linked
provider token and fresh SE-key proof must pass `POST /v1/enroll` even when a
local Darkbloom profile exists. Only then does the CLI return "Already enrolled",
without saving or reinstalling the profile. New identities require macOS 27 or
later and qualified App Attest, not a copied profile or OS-only grant.
`ProviderOnboardingPolicy` in
`provider-swift/Sources/ProviderCore/Auth/ProviderOnboardingPolicy.swift` owns the
OS choice and the upgrade/upcoming MDM deactivation notice. The OS choice never
grants serving authorization or removes an existing profile.

| Command | Flag | Type | Default | Effect |
|---|---|---|---|---|
| `enroll` | `--coordinator <url>` | `String?` | config URL | Coordinator to request the profile from |
| `enroll` | `--no-open` | flag | `false` | Save the `.mobileconfig`; do not open System Settings |
| `unenroll` | `--force` | flag | `false` | Select full exit, stop the service and confirm local-data cleanup without prompting |
| `unenroll` | `--no-open` | flag | `false` | Do not open System Settings |
| `unenroll` | `--keep-serving` | flag | `false` | Require fresh coordinator App Attest removal readiness, preserve identity/account data and guide removal of only Darkbloom enrollment |

### `darkbloom logs`

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--file` | flag | `false` | Tail `~/.darkbloom/provider.log` instead of unified logging |
| `-f`, `--follow` | flag | `false` | Stream new lines |
| `--last <duration>` | `String?` | `nil` | `log show --last <duration>`; with `--follow`, history first then live stream |
| `--debug` | flag | `false` | Include debug-level entries (unified logging only) |
| `-l`, `--lines <n>` | `Int` | `50` | Lines to show; only with `--file` |

Without flags: `log stream --predicate 'subsystem == "dev.darkbloom.provider"' --level info`.

Where `logs` and [`report`](#darkbloom-report) wait for a `log` child to finish, they take its exit from `ProcessExitObserver` (its termination handler), which does not run the calling thread's run loop.

| Flag | Description |
|------|-------------|
| `--coordinator-url <url>` | Override the coordinator WebSocket URL |
| `--model <id>` | Model to serve; repeatable (skips the interactive picker) |
| `--all` | Serve all downloaded models |
| `--idle-timeout <mins>` | Idle-memory policy, saved to `[backend] idle_timeout_mins` (0 = always ready); skips the memory prompt |
| `--foreground` | Run in the foreground (used by launchd; normally implicit) |
| `--local` | Only me: serve the local API only; do not connect to the coordinator |
| `--local-endpoint` | Both, me first (older flag): serve the local API beside the coordinator; Darkbloom requests pause while you use it and for `[local] me_first_idle_minutes` after (`[local] me_first`) |
| `--port <port>` | This Mac's local API port, used and saved (default `[local] port`, else the one this Mac's local API already uses, else the first free from 8001; saved the first time) |
| `--bind <addr>` | Bind address for local modes (default 127.0.0.1) |
| `--no-auth` | Disable local API-key auth (trusted/airgapped only) |

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--last <duration>` | `String` | `24h` | Window of unified logs to collect |
| `--dry-run` | flag | `false` | Print the report; do not upload |

After the model picker, an interactive `darkbloom start` asks how the machine
should treat its memory when nobody is sending requests:

```
Memory when idle
  1) Always ready    Keep models loaded (~18 GB while idle). Instant responses,
                     full base rewards.
  2) Free when idle  Unload after 60 min without requests; reload on demand
                     (~10-30 s cold start). Your Mac gets its memory back.
  3) Custom          Choose the number of idle minutes.
  Choice [2]:
```

Enter keeps the policy already in force (`Free when idle` on a fresh install).
The answer is written to `[backend] idle_timeout_mins` for ordinary coordinator-connected
idle unloading; `--model`/`--all`, `--idle-timeout`, non-interactive runs and the
launchd relaunch never prompt. Autopilot enrollment also skips this prompt and
preserves the saved policy. See [`darkbloom idle`](#darkbloom-idle).
Every `darkbloom start` mode preloads selected models with the default
`startup_preload = true`, regardless of the idle-memory policy. A scheduled
provider begins this loading at the window opening, not beforehand.
A coordinator-connected provider prioritizes previously loaded models and
defers registration for up to `startup_preload_timeout_secs`; Only me
(`--local`) finishes preloading before it listens. An explicit `[backend]
preload_models` list takes precedence. The slot limit and available memory
can leave models to load on a later request. `startup_preload = false`
disables preloading in either mode. The one-token `startup_selftest` and
`startup_selftest_fail_closed` settings apply only to coordinator-connected
startup; `--local` does not run a synthetic decode.

Enrolled Autopilot can advertise more cached models than the saved serving
selection. `startupPreloadPlan` preserves saved explicit or implicit preferences;
that larger inventory does not replace `enabled_models`/`preload_models` or ask
startup to load every advertised model
(`provider-swift/Sources/ProviderCore/ProviderLoop+StartupPreload.swift`, `startupPreloadPlan`).

Examples:

### `darkbloom autoupdate <action>`

| Positional | Type | Default | Effect |
|---|---|---|---|
| `action` | `String` | — (required) | `enable`/`on`/`true`, `disable`/`off`/`false`, or `status`; anything else exits 1 |

Writes `provider.auto_update` to the config file under the shared config lock,
reloading the file before saving so a concurrent live switch's model selection
is retained.

### `darkbloom autopilot`

Experimental enrollment for the verified downloaded network inventory; off by default.
Opt-in records interest/consent for the default shadow rollout, not active
memory-residency control.
Source: `provider-swift/Sources/darkbloom/Autopilot/AutopilotCommand.swift` (`Autopilot`) and
`provider-swift/Sources/darkbloom/Start/StartCommand+Autopilot.swift` (`saveAutopilotEnrollment`).
Every subcommand accepts `--config`.

| Command / option | Effect |
|---|---|
| `status`, `status --json` | Configured consent and fresh daemon state, including selected/ready models and transition result. `Also downloaded` lists the verified downloaded catalog builds the running provider adds to the Autopilot set; `Downloads` shows whether Autopilot downloads are on, their limits, the models and GiB Autopilot downloaded that are still on disk, and free disk (`downloads` and `download_usage` in JSON) |
| `enable` | Discover/verify all eligible downloaded network builds and safely save experimental enrollment; normal startup selector, verification adds no downloads, default shadow mode is inactive, and an already-enrolled provider's pause is preserved |
| `models` | Explicitly refresh the recorded cached network inventory through discovery, verification and safe drain/restart; normal startup selector and no implicit resume |
| `pause`, `resume` | Runtime participation update; pause preserves ready models and blocks new demand-based changes. Resume follows the coordinator's current mode and never promotes shadow to live. Retired, unadvertised residents may still unload when unpinned and unused |
| `pin MODEL_ID...`, `unpin MODEL_ID...` | Live unload protection during active control, explicit pause or an accepted operation; pins must belong to the selected set |
| `downloads enable [--max-storage-gb N] [--max-models N]` | Turn Autopilot downloads of catalog models on your behalf back on and set limits (on by default while enrolled). Each run replaces both limits: an omitted flag means no limit; on an interactive terminal without flags it asks for both, and a blank answer means no limit. Writes `[backend.autopilot_downloads]` and never changes consent ([configuration](../reference/configuration.md#provider-model-selection)) |
| `downloads disable` | Stop Autopilot downloads; models it downloaded stay on disk and in the Autopilot set |
| `disable` | Revoke new commands and restore the saved idle policy after any accepted operation finishes |
| `start --autopilot`, `start --autopilot --all` | Explicit scripted enrollment of all verified eligible downloaded network builds; `--all` cannot include arbitrary local/off-catalog models |
| `start --no-autopilot` | Explicitly save the ordinary idle-policy mode |

Every normal interactive `start` asks about experimental Autopilot again,
explicitly naming shadow mode as not activated and a later live rollout. The
first default is No (`[y/N]`); later prompts use the saved choice (`[Y/n]` when
enrolled). Enter keeps that default. Explicit enrollment flags and automatic
restarts do not prompt. Both answers follow the ordinary model picker and
idle-policy prompt. Yes records consent, not activation; the normal selector may
download models the operator explicitly chooses.
It discovers all already-downloaded active network-supported catalog models and
verifies their manifest or matching registry weight hash. Arbitrary local,
off-catalog, retired, ineligible, malformed, stale or unverified builds are excluded;
verification failures warn and skip the build. Empty eligible inventory fails
before persistence, drain or restart; verification adds no downloads.
The normal selector saves the chosen startup models and idle policy. Enrollment
itself leaves other preferences unchanged; explicit `--idle-timeout` remains a
requested override. Autopilot does not change residency in the current shadow
rollout. Live rollout can later choose cached models for utilization, not an
earnings guarantee.

Discovery filters empty or over-`256`-UTF-8-byte IDs before verifying builds.
Inventory validation deduplicates and sorts the verified result, then requires
`1...256` approved IDs through the shared `ModelAutopilotSettings.hasConsent`
predicate before persistence or drain (`validatedAutopilotSelection`,
`verifiedAutopilotInventory` in
`provider-swift/Sources/darkbloom/Start/StartCommand+Autopilot.swift`). Invalid
bounds fail without stopping the existing daemon or installing a replacement.

The recorded inventory is an exact-build allowlist. Ordinary starts with saved
enrollment validate all recorded IDs or fail before persistence or drain: a
missing, ineligible or unverified build, including a transient manifest error,
cannot silently shrink consent. The saved selection never grows by itself, but
with saved consent the running provider adds every verified catalog build in
the cache, including builds Autopilot downloads on the operator's behalf and
verified coordinator-desired replacements, to the Autopilot set it reports
([Autopilot set](../architecture/model-autopilot.md#the-autopilot-model-set)).
Explicit `--autopilot`, `enable` or `models` refreshes eligible cached inventory
without downloading and may exclude/prune failed or ineligible builds.
`saveAutopilotEnrollment` retains `paused` when consent already exists, including
ordinary starts and explicit refresh/`enable`; only `resume` resumes that
enrollment. New or previously disabled enrollment starts unpaused.
While enrolled, `darkbloom switch`
returns a busy receipt with that guidance; disable Autopilot to use manual switching. Optional MTP may fall back to
target-only serving without an Autopilot download. Files stay on disk.

A valid shadow lease produces `shadow`, explicitly not activated, with
`active=false` and `observe_only=true`. `waiting` means no valid lease is
acknowledged. Consent and shadow control retain ordinary loading and idle behavior.
Only a matching live lease after an operator permits live rollout and selects
the verified machine can produce `active`; providers have no shadow/live mode
command. The coordinator-issued `Machine ID` in `darkbloom status` is the cohort
selector, not a provider connection ID or serial. An unselected machine stays
shadow even when other machines are live. `paused` retains ready
models; `recovering` means an accepted transition is still settling. Policy changes
are consumed at the next capacity poll. `models` uses the existing safe restart.
See [architecture](../architecture/model-autopilot.md) and
[operator procedures](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/model-autopilot.md).

## `darkbloom beta`

| Subcommand | Flag / positional | Type | Default | Effect |
|---|---|---|---|---|
| `list` (default) | `--json` | flag | `false` | Table or JSON of every feature with `on`/`off`/`auto` |
| `status` | `[feature]` | `String?` | all | Details for one or all features |
| `enable` | `<feature>` | `String` | — | Write the feature's config key on |
| `disable` | `<feature>` | `String` | — | Write it off |

Feature ids and semantics: [beta features](./beta-features.md).

### `darkbloom fan`

| Subcommand | Flag | Type | Default | Effect | Needs `sudo` |
|---|---|---|---|---|---|
| `status` (default) | `--json` | flag | `false` | Helper install/load state, policy, temperatures | no |
| `diagnose` | `--json` | flag | `false` | Fans and GPU sensors detected | no |
| `enable` | `--speed <pct>` | `Double` | `80` | Target, % of each fan's maximum; `60`–`90` accepted | yes |
| `enable` | `--temperature <C>` | `Double` | `45` | Engage threshold; release is `--temperature − 5` | yes |
| `configure` | `--speed <pct>` | `Double?` | `nil` | Change speed only | yes |
| `configure` | `--temperature <C>` | `Double?` | `nil` | Change threshold only; at least one of the two is required | yes |
| `disable` | — | | | Restore automatic control; keep the helper installed | yes |
| `uninstall` | — | | | Restore automatic control; remove helper and LaunchDaemon | yes |
| `test-lease` (**debug builds only, hidden**) | `--seconds <n>` | `Int` | `30` | Hold a provider activity lease for 1–300 s | no |

## `darkbloom idle`

Manage the idle-memory policy: whether a model stays loaded while the machine
receives no requests, or is unloaded to give the memory back and reloaded on
demand. The single source of truth is `[backend] idle_timeout_mins` in
`provider.toml` (0 = always ready); `darkbloom start`'s memory prompt and
`--idle-timeout` write the same key, and the launchd plist never carries it.

```bash
darkbloom idle status                 # current policy and where it is set (default)
darkbloom idle keep-loaded            # always ready: models stay loaded
darkbloom idle unload-after <minutes> # free when idle: unload after N idle minutes (1..10080)
```

| Policy | `idle_timeout_mins` | Effect |
|--------|---------------------|--------|
| Always ready | `0` | Models stay resident; instant responses; the machine stays eligible for base rewards the whole time |
| Free when idle (default) | `60` | A model with no requests for 60 min is unloaded; the next request reloads it (~10-30 s cold start) |
| Custom | `N` | Same as above with an `N`-minute window |

Changes are saved with the same locked read-modify-write as `darkbloom beta`
and take effect after `darkbloom restart`. The provider reports the policy in
its heartbeat (`idle_unload_mins`) so the dashboard shows an empty slot as
"sleeping, wakes on demand" rather than as a fault. `--json` prints the policy
machine-readably.

## `darkbloom addon`

Operator debugging of [add-on holds](../architecture/addon-hold.md): inspect,
place or release the hold a local add-on uses while its VMs run. The commands
reach the running provider through its owner-only lifecycle mailbox, bound to
the live process identity; add-ons themselves use the
[local socket](../reference/addon-hold-ipc.md).

```bash
darkbloom addon [status]
darkbloom addon hold [--lease-seconds <30...600>]
darkbloom addon release [--force]
```

| Subcommand / flag | Default | Effect |
|---|---|---|
| `status` | default subcommand | Active holds (add-on, `draining` or `held`, start time, lease) and whether an add-on holds the machine lock |
| `hold --lease-seconds <n>` | `600` | Hold as add-on `operator`, exactly like an add-on: admission closes, accepted work finishes (up to 120 s), every model unloads. Repeating renews the lease |
| `release` | — | Release every active hold; the provider serves again at once on the same connection |
| `release --force` | `false` | Release even while an add-on holds the machine lock, so its VMs may still be using memory |

Without `--force`, `release` refuses while the machine lock is held. A provider
without add-on support (older, or an Only me `--local` server) is refused
before anything is sent. The command waits up to 10 seconds for the provider's
answer. `darkbloom status` prints `Not serving: held by add-on …` while held.
Code: `provider-swift/Sources/darkbloom/AddonCommand.swift` (`Addon`),
`provider-swift/Sources/ProviderCore/Addon/ProviderLoop+AddonHold.swift`
(`handleAddonControl`).

## `darkbloom sandbox`

Set up and manage [Darkbloom Sandbox](./sandboxes.md) on this Mac: approved
GitHub Actions jobs in Linux and macOS VMs, run by the separately installed,
closed-source add-on `DarkbloomSandbox.app` in `~/DarkbloomSandbox`. Every
subcommand runs the add-on's own command; only `setup` contacts the sandbox
service, to download the add-on's installer. Code:
`provider-swift/Sources/darkbloom/Sandbox/SandboxCommand.swift` (`Sandbox`).

```bash
darkbloom sandbox [status [--json]]
darkbloom sandbox setup [--yes] [--no-browser] [--linux-slots <n>] [--macos-slots <n>] [--disk <volume>]... [--wait-ready] [--server <url>]
darkbloom sandbox pause | resume
darkbloom sandbox logs [-f] [-n <lines>]
darkbloom sandbox uninstall [--yes]
```

| Subcommand / flag | Default | Effect |
|---|---|---|
| none, `status` | — | One screen: the state, what it means for inference, free slots, images, host, last update check and console. Without the add-on: what sandboxes are and how to set them up. `darkbloom sandbox --help` shows the group's help |
| `status --json` | `false` | The add-on's `status --json` output, unchanged. Without the add-on, a schema 1 `not_installed` document; an add-on that cannot answer exits `1` |
| `setup` | — | Check, explain, confirm, install and summarize; see [Setup](#setup) |
| `setup --yes`, `-y` | `false` | Skip the confirmation |
| `setup --no-browser` | `false` | The installer does not open the approval page; open the printed link |
| `setup --linux-slots <n>`, `--macos-slots <n>` | what fits the Mac | Jobs at a time: Linux `0`–`16`, macOS `0`–`2`; both `0` is refused. The plan and the install take a chosen count as it is; setup shows it as `(your choice)` |
| `setup --disk <volume>` | none: the internal disk | Repeatable. A work disk for the VM images and jobs, such as `/Volumes/FastSSD`; `~` keeps the internal disk as well. Setup makes each path absolute, checks it (see [Setup](#setup)) and passes it on in order. Needs an add-on release with work disks (1.2.0 or later). The add-on, its settings and logs stay in `~/DarkbloomSandbox` |
| `setup --wait-ready` | `false` | The installer waits until the images are downloaded and the Mac takes jobs |
| `setup --server <url>` | `https://api-sandbox.darkbloom.dev` | Where `install.sh` comes from: an `https` URL without credentials, query or fragment |
| `pause` | — | `darkbloom-sandbox pause`: running jobs finish, no new jobs; then prints how many still run |
| `resume` | — | `darkbloom-sandbox resume` |
| `logs` | `-n 50` | `tail` of `~/DarkbloomSandbox/agent/agent.log`; `-f`/`--follow` runs `tail -F`; `-l` is the same as `-n`/`--lines` |
| `uninstall` | — | Says what stops (running jobs end unpaid), asks, then runs `darkbloom-sandbox uninstall --yes` with the terminal. `--yes`/`-y` skips the question; without a terminal it is required |

### Setup

1. **Waitlist.** Setup refuses `sudo`. A first setup then asks the coordinator of `provider.toml`
   whether Darkbloom approved this account from the `sandbox` waitlist
   (`GET /v1/waitlists/sandbox` with the `darkbloom login` token) before it
   checks or installs anything. Approved, or a coordinator without that
   waitlist (it answers `404`, as one without waitlists does): setup goes on.
   Not on the waitlist: setup offers to join it (`--yes` joins without asking)
   as [`darkbloom waitlist sandbox`](#darkbloom-waitlist) does, with the body
   `{}`, and then treats the join's answer the same way; declined, or without
   a terminal and without `--yes`, it prints the join command and stops.
   Waitlisted or revoked: setup shows the status and stops. Not logged in
   (`401`) or refused (`403`): setup says to run `darkbloom login` and stops.
   No usable answer (unreachable, a 10-second timeout, or any other answer):
   setup says why, says to check the network and run it again, and stops. A
   `404` prints `<coordinator> has no Darkbloom Sandbox waitlist; going on.`
   first. Its lines name the waitlist by the coordinator's `title`, and
   `Darkbloom Sandbox` when there is no answer. Each stop exits `1`; a setup
   that continues, repairs or updates an installed add-on does not ask
   (`provider-swift/Sources/darkbloom/Sandbox/SandboxSetupCommand.swift`,
   `SandboxSetupFlow.requireApproval`; the outcomes are
   `provider-swift/Sources/darkbloom/Waitlist/FeatureWaitlistGate.swift`,
   `FeatureWaitlistGate`, which [`darkbloom cluster`](#the-cluster-waitlist-gate)
   shares).
2. **Check.** Prints chip, macOS, desktop session, network, power and sleep
   in the `doctor` style (`[PASS]`, `[WARN]` with a `↳ fix:` line, `[FAIL]`). A
   refusal (table below) prints `Not eligible` and stops before anything is
   downloaded
   (`provider-swift/Sources/darkbloom/Sandbox/SandboxEligibility.swift`,
   `SandboxEligibility`; measurements in `SandboxHostProbe`).
   With `--disk`, one `Work disk` line follows per disk, from `statfs` on the
   path (or its nearest existing parent). A path under `/Volumes/<name>` must be
   on the volume mounted there, and the volume must be APFS with ownership on.
   A disk that fails stops setup before anything is downloaded, with the fix:
   for ownership off, the exact command, such as
   `sudo diskutil enableOwnership /Volumes/FastSSD`. At a prompt and without
   `--yes`, setup then asks `Turn ownership on for /Volumes/FastSSD now?`
   (default no). On yes it runs that command in the terminal's foreground
   process group, so sudo asks for the password itself; the CLI never reads it.
   Then setup checks the disk again. If the command fails, setup prints
   `Ownership is still off on …` and stops. With `--yes` or without a terminal,
   setup prints the command and stops. Setup never formats a drive. The
   installer checks each disk again by the add-on's own rules (local, writable,
   not a disk image)
   (`provider-swift/Sources/darkbloom/Sandbox/SandboxWorkDisk.swift`,
   `SandboxWorkDisk`).
3. **Download.** Downloads `<server>/install.sh` over HTTPS: a redirect is
   followed only to another `https` URL, and the response must be HTTP 200 over
   `https`, at most 1 MiB, with a `#!` first line naming a shell. The script is
   written as a `0600` file in a new `0700` directory, run with `/bin/sh` for
   the plan and the install, and removed afterwards. The installer verifies the
   add-on release before it installs it; the CLI does not verify the script
   beyond TLS (`provider-swift/Sources/darkbloom/Sandbox/SandboxInstaller.swift`,
   `SandboxInstaller`). With `--disk`, a script that does not name `--disk`
   comes from a release without work disks: setup says that work disks need
   add-on 1.2.0 or later and stops, changing nothing.
   **Drive choice.** On a first setup without `--disk`, at a prompt and
   without `--yes`, a script that names `--disk` makes setup list the drives
   that can take the VM images and jobs, under `Where the VM images and jobs
   go`: `1) This Mac's internal disk`, then one line per drive with its free
   space, and a note when its ownership is off. A drive is listed when it is
   mounted at its own `/Volumes/<name>`, shows in Finder, is local, writable
   and APFS, and has room for its floor (a tenth of the drive, 50 to 100 GiB)
   plus a Linux job and its images (34 GiB). Setup asks `Choose 1-N [1]:`;
   Enter or the end of input keeps the internal disk, and any other answer
   that is not a listed number asks again. A chosen drive gets the `Work disk`
   check above (with the ownership offer) and goes to the plan and the install
   as one `--disk`. The plan's lines then follow under `The add-on's plan for
   this Mac`.
4. **Plan.** A script that names `--plan` (add-on 1.1.1 and later) runs with
   `--plan --json-progress` and the owner's slot options, without `--yes` and
   with stdin closed. It verifies the release, runs the add-on's own checks and
   sizing, installs nothing and prints one
   [`plan` event](#installer-progress-events). The CLI prints the plan's CPU,
   memory and disk lines, such as `Disk: 157 GiB free; 100 GiB stays free for
   you; Linux images 4 GiB + 30 GiB per Linux job; macOS images 46 GiB + 40 GiB
   per macOS job`, then a verdict and the jobs this Mac can run at a time
   (`SandboxSizingPlan`). Ctrl-C or a signal during the plan stops setup. An
   installer without plan mode, a failed plan or a run without a `plan` event
   gets the CLI's fallback estimate instead, after an `[INFO] Sizing` line
   (`SandboxEligibility.estimatedPlan`). The add-on's rules as of 1.1.1, which
   the fallback repeats:

   | Rule | Value |
   |---|---|
   | Kept for the owner | A quarter of the cores (at least 2) and of the memory (at least 8 GiB) |
   | Kept for inference | Another quarter of the memory, when the provider runs or its add-on socket exists |
   | Linux job | 4 cores, 16 GiB and a 30 GiB scratch disk; at most 16 |
   | macOS job | 8 cores, 16 GiB and a 40 GiB disk budget; at most 2, macOS's limit, which counts the owner's own macOS VMs |
   | Order | Linux, macOS, Linux, macOS, then Linux only, while cores, memory and disk last |
   | Free-space floor | A tenth of the home folder's volume, between 50 and 100 GiB, stays free |
   | VM images | Charged with a platform's first job: Linux 4 GiB, macOS 46 GiB; nothing once installed |
   | Most requested macOS size | 12 cores and 32 GB: reported as fitting when 12 cores and 32 GiB are left for jobs, which takes 16 cores and about 64 GB beside inference |
   | Refused | Not Apple silicon, macOS before 27, no network, or this user not logged in at the Mac's desktop (`/dev/console` owner), where the add-on runs |
   | Warned, not refused | Wi-Fi, a laptop on battery, system sleep on the power adapter (`pmset -g custom`; `SleepDisabled 1` counts as off) |

   Examples: 16 cores and 128 GB run 1 Linux and 1 macOS job; 12 cores and
   32 GB run 1 Linux job; 8 cores and 16 GB are not eligible. With 157 GiB free
   on a 1858 GiB volume, 100 GiB stays free and the other 57 GiB hold the Linux
   images and one Linux job: 1 Linux job, no macOS job. When no job fits, the
   verdict gives the plan's message and the GiB to free for one Linux job and
   for one macOS job, and setup stops before installing.

   When the add-on's plan gives macOS no job and its `macos_limit` names disk,
   setup prints one more line under the verdict
   (`SandboxSizingPlan.freeSpaceNote`): the plan's free space is what `df -h ~`
   shows as Avail; Finder also counts purgeable space, which macOS frees only
   when it needs to (restarting, or removing Time Machine local snapshots, which
   `tmutil listlocalsnapshots /` lists, frees it now); then
   `A macOS job needs about N GB more`. N is `diskShortfall` for a macOS job
   beside the plan's slots: the floor, the disk the plan's slots take (each
   platform's images with its first slot, one job's disk per slot) and a macOS
   job with its images, less the free space, in GiB rounded up, which the CLI
   writes as GB like its memory figures. With 210 GiB free and 3 Linux jobs
   planned, a lone macOS job would fit above the floor, but beside the Linux
   jobs it needs about 70 GB more. When no job fits, N equals the verdict's GiB
   for one macOS job. The fallback estimate gets no such line.
5. **Confirm.** Explains that inference pauses while a job runs, that each job
   pays its price minus a 10% fee into the Darkbloom balance, the VM images and
   the one browser approval, then asks `[y/N]`. `--yes` skips it; without a
   terminal and without `--yes`, setup stops before installing.
6. **Install.** A script that names `--json-progress` runs with
   `--json-progress --yes` and the owner's `--no-browser`, `--wait-ready` and
   slot options and each `--disk <path>`, with stdin closed, and its stages render as
   [progress events](#installer-progress-events). Any other script is an older
   installer: it runs with the terminal and only the slot options, and the CLI
   says so.
7. **Summarize.** Reads `status --json` again: the state, the jobs at a time and
   the next commands.

While the installer runs, Ctrl-C reaches the installer, not the CLI, and setup
exits `130`; an enrollment waiting for approval goes on. With add-on 1.1.2 and
later, whose approval and waitlist events say `background: true`, the wait
also survives a restart and the Mac enrolls by itself, so the window can close:
setup says so and points at `darkbloom sandbox status`. With an earlier add-on,
a rerun follows the waiting enrollment, and a restart ends the wait, so setup
must run again.
A failed installer's exit status becomes the CLI's, after the stage marked ✗,
its `failed` message and the last lines of its stderr that do not repeat it.

Rerunning `setup` decides from the add-on's answer
(`provider-swift/Sources/darkbloom/Sandbox/SandboxSetupCommand.swift`,
`SandboxSetupPlan`):

| Add-on answer | `setup` |
|---|---|
| No add-on, or `not_installed` | A first setup: check, plan, explain, confirm, install |
| `waiting_for_approval`, `waitlisted`, `enrolling` | Runs the installer again to continue, without the check or the question |
| `stopped`, `error`, no answer within 10 s, a failed status, an add-on older than `status --json` | Runs the installer again to repair or update the add-on |
| `ready`, `running`, `paused`, `downloading_images`, `updating`, an unknown state | Reports the state, then checks the plan again (below); with `--linux-slots`, `--macos-slots` or `--disk` it runs the installer to apply them, without the plan, after the `Work disk` lines. The report offers `--disk` only when the add-on's `status --json` has a `disks` member |

On a Mac that is set up, after the report, setup downloads the installer and
runs its plan as for a first setup, which changes nothing, and compares the
plan's `linux_slots` and `macos_slots` with the installed `slots.linux.total`
and `slots.macos.total` (`SandboxSlotChange`):

| Case | `setup` |
|---|---|
| Same counts, no plan (an installer without `--plan`, a failed plan), a plan without a job, no `slots` in the status, or a failed download | Today's report exactly: the state, then `To change how many jobs run at a time: darkbloom sandbox setup --linux-slots <n> --macos-slots <n>`, without the free-space line; a failed download adds why it could not check |
| `jobs_running` above `0` | No plan: the add-on's installer refuses a slot change while jobs run (exit `4`; the CLI never passes `--force`), and their disk would shrink the plan. Setup says to run it again once they finish |
| Different counts, at a terminal | The plan's CPU, memory and disk lines and the free-space line when it applies, then `This Mac now fits <L> Linux + <M> macOS (installed: <l> Linux + <m> macOS). If a job is running, the installer refuses and changes nothing. Apply? [Y/n]`. Yes or an empty answer runs the installer with the plan's counts as `--linux-slots` and `--macos-slots`; no prints the command that applies it |
| Different counts, `--yes` or no terminal | The same lines, then `This Mac now fits …` without the question. Applies the plan only when it adds slots and removes none; otherwise prints `Not applied` and the command that applies it, and exits `0` |

A platform missing from `slots` counts as `0`: the add-on configures and
reports only platforms with a slot. When the installer finds that a job
started since the status, it refuses with exit `4` and changes nothing; setup
prints the exit `4` advice below and exits `4`.

### Installer progress events

These are the add-on's command contract as of add-on 1.0.1 (schema 1): new
fields and events may appear without a new schema, so unknown ones are
ignored; other stdout lines show as text, and stderr is kept for the error
report (`provider-swift/Sources/darkbloom/Sandbox/SandboxSetupProgress.swift`,
`SandboxInstallerEvent`, `SandboxSetupRenderer`). With `--json-progress` the
installer writes one object per line: `{"schema":1,"event":"stage","stage":…,
"step":n,"steps":8,"status":…,"message":…}` with the stage's own fields beside
them, and a successful run ends with one `{"event":"summary",…}`.

With `--plan --json-progress` (add-on 1.1.1) the installer exits 0 after one
`{"schema":1,"event":"plan",…}` line. The CLI reads `message`, `linux_slots`,
`macos_slots`, `linux_automatic`, `macos_automatic`, `linux_limit`,
`macos_limit`, `free_bytes`, `floor_bytes`, `linux_images_bytes`,
`macos_images_bytes`, `linux_slot_bytes`, `macos_slot_bytes`, `cores`,
`cores_kept`, `memory_bytes`, `memory_kept_bytes` and `provider_memory_bytes`
(`SandboxSizingPlan`), and from `disks` (releases with work disks) each
entry's `path`, `root_volume`, `free_bytes`, `floor_bytes`, `linux_slots` and
`macos_slots`. When the plan uses an external disk or more than one disk, an
`[INFO] Work disk` line per disk follows the `Disk` line, such as
`/Volumes/FastSSD: 900 GiB free; 93 GiB stays free; 2 Linux jobs, 1 macOS job`.
It ignores `root`, `volume_bytes` and unknown members. A line with another
schema or without one of the numbers is not a plan. With `--disk`, a failed plan
(exit `2` when the installer refuses a disk) stops setup with the installer's
last stderr lines and its exit status, since the CLI's estimate knows no work
disks; without `--disk`, setup falls back to the estimate as before.

| `status` | Meaning | The CLI |
|---|---|---|
| `started` | A stage begins; `message` is its title | The stage becomes the running line |
| `progress` | Something while the stage runs | The approval link and code or the waitlist print at once; download progress updates the running line; another `message` prints under the stage when it ends |
| `done` | The stage ended; `message` is its one-line result | `✓ Title`, then the stage's messages |
| `failed` | The last event of a failed run; `message` and `exit_code` | `✗ Title` and the message; stderr lines that only repeat it are dropped |

| `stage` | Line | Fields the CLI reads |
|---|---|---|
| `checking_mac` | Checking this Mac | — |
| `verifying_release` | Verifying release | — |
| `installing` | Installing | — |
| `waiting_for_approval` | Waiting for approval, or waiting for Darkbloom to approve the account | `progress` with `user_code`, `verification_uri`, `verification_uri_complete` (or `null`) and `browser_opened`; `progress` with `waitlisted: true`; on both, `background` (add-on 1.1.2 and later; absent or not a boolean reads as `false`) |
| `enrolled` | Enrolled | — |
| `starting` | Starting | — |
| `downloading_images` | Downloading images N% | `progress` (0 to 1) with `--wait-ready` |
| `ready` | Ready | — |
| another | its `started` message | — |

`background: true` on the approval or waitlist event says that the wait goes on
without the installer, also across restarts, and that the Mac enrolls by itself
once approved (`SandboxSetupRenderer.waitsInBackground`). The waitlist text
under the approval link then says that the window can close, that this Mac
keeps waiting and enrolls by itself once the account is approved, and that
`darkbloom sandbox status` shows where it is. Without it, the text says to leave
setup running, or to press Ctrl-C and run `darkbloom sandbox setup` again later.
The wait counts as over once the `enrolled` stage is `done`.

The summary's `slots` (`linux`, `macos`: `count`, `automatic`, `limit`) and
`console_url` feed the setup summary. On a terminal the running stage is the
last line, with a spinner, and turns into ✓ or ✗ when it ends; elsewhere each
stage prints once, when it ends, and `--wait-ready` download progress prints
every tenth.

| Installer exit status | `setup` says |
|---|---|
| `0` | The summary: state, jobs at a time (automatic and the limit, or your choice), next commands |
| `2` | This Mac cannot host Darkbloom Sandbox as it is (the failed stage says why) |
| `3` | Not enrolled: the code was denied or expired, or the waitlist request ended; run `setup` to start again |
| `4` | A job is running, so the installer changed nothing (it refuses rather than waits); run `setup` again when it finishes, `pause` meanwhile. Setup never passes the installer's `--force`, which would stop running jobs, and stopped jobs aren't paid |
| `130` | Stopped; an enrollment waiting for approval goes on, and a rerun follows it. While the Mac waits in the background (`background: true`, not yet enrolled): it keeps waiting, also across restarts, and enrolls by itself; `sandbox status` shows where it is |
| other | Setup did not finish; it is safe to rerun |

### Add-on commands

| Command the CLI runs | By | Bound |
|---|---|---|
| `darkbloom-sandbox status --json` | `darkbloom status`; `status`, `setup`, `pause`, `resume` and `uninstall` | 2 s for `darkbloom status`, 10 s otherwise; SIGKILL after it |
| `darkbloom-sandbox pause`, `resume` | `pause`, `resume` | 60 s |
| `darkbloom-sandbox uninstall --yes` | `uninstall` | none; terminal attached |
| `darkbloom-sandbox status` | `status`, for an add-on older than `status --json` | none; terminal attached |

`status --json` exits `1` when nothing is installed and still prints its
document, so the CLI reads stdout whatever the exit status. `pause` and
`resume` exit `0` (also when already so) and `1` when nothing is installed,
which the CLI reports as not set up. `status --json` (schema 1, every member
present, nullable ones as `null`) is decoded leniently: only an integer
`schema` of 1 or more and a string `state` are required, so older and newer
add-ons still render (`provider-swift/Sources/darkbloom/Sandbox/SandboxAddon.swift`,
`SandboxAddonStatus`).

| Field | Type | Use |
|---|---|---|
| `schema` | integer | `1` |
| `installed` | bool | `false` reads as not set up |
| `version` | string | Shown in the heading |
| `host_id` | string or null | Shown as `Host` |
| `state` | `not_installed`, `waiting_for_approval`, `waitlisted`, `enrolling`, `downloading_images`, `ready`, `running`, `paused`, `updating`, `stopped`, `error` | The heading; another value shows as text |
| `detail` | string | The line under the heading, except for `ready`, `running`, `paused` and `stopped`, where the CLI says what the state means for inference and which command to run |
| `slots.linux`, `slots.macos` | `{"total": n, "free": n}` | Free slots while the agent reports (`ready`, `running`, `paused`, `updating`); a platform without slots is left out |
| `jobs_running` | integer | `running N jobs` |
| `images` | `[{"platform": "linux" \| "macos", "state": "installed" \| "downloading" \| "missing", "progress": 0..1 or null}]` | Images line and the download percentage |
| `accepting` | bool | A ready Mac with `false` shows the add-on's `detail` |
| `last_update_check` | Unix seconds or null (milliseconds and ISO 8601 are read too) | `Updates` line |
| `console_url` | string | `Console` line and the setup summary |
| `disks` | `[{"path", "root_volume", "state", "detail", "free_bytes", "slots": {"linux": {"total"}, "macos": {"total"}}, …}]` (add-on releases with work disks) | The member's presence means the add-on takes `--disk`. When it lists an external drive or more than one disk, one `Work disk` line per disk follows `Images`, such as `/Volumes/FastSSD: online, 812 GiB free; slots: Linux 2, macOS 1`. A disk that is not `online` adds its `detail` in parentheses. An entry without `path` or `state` is skipped |

An add-on that answers with exit status `64` or its usage on stderr predates
the option or action: `status` then shows the add-on's own `status` output,
`pause` and `resume` say to update it with `setup`, and `darkbloom status` says
it is installed.

## `darkbloom waitlist`

Darkbloom opens some features, such as clusters and Darkbloom Sandbox, to the
accounts it approves from a waitlist per feature. A waitlist is per account:
the account joins it and Darkbloom approves the account, not a Mac, so a join
sends nothing about this Mac. The coordinator's catalog is the only list of
waitlists: the CLI asks it which waitlists exist and takes each one's title and
start command from its answer. Bare `darkbloom waitlist` lists every waitlist
and where the account stands; `darkbloom waitlist <name>`, such as
`darkbloom waitlist cluster` or `darkbloom waitlist sandbox`, puts the account
on one and shows where it stands. Admins approve accounts on the coordinator.
Code:
`provider-swift/Sources/darkbloom/Waitlist/WaitlistCommand.swift`
(`Waitlist`, `FeatureWaitlistCommand`, `FeatureWaitlistAccess`),
`provider-swift/Sources/darkbloom/Waitlist/FeatureWaitlist.swift`
(`FeatureWaitlistClient`, `FeatureWaitlists`, `FeatureWaitlistPlace`) and
`provider-swift/Sources/darkbloom/Waitlist/FeatureWaitlistView.swift` (`FeatureWaitlistView`).

```bash
darkbloom waitlist [--json] [--config <path>]
darkbloom waitlist <name> [--json] [--config <path>]
```

| Argument / flag | Default | Effect |
|---|---|---|
| no `<name>` | — | Every waitlist in the coordinator's order: its title and id, its summary and where the account stands (`not joined`, `#<n> in line`, `approved since <day>` with the start command, `not approved`), then `Join one: darkbloom waitlist <name>` while one is not joined |
| `<name>` | — | Puts the account on that waitlist, then shows where it stands: its place in line, or the approval with the waitlist's start command. Joining again keeps the place, and an approved or revoked account stays as it is; a revoked account's join exits `1`. The name is a waitlist's id ignoring case, or that id with a plural `s` or `es` (`clusters`, `sandboxes`); an exact id wins over another id's plural, and a plural that two ids share names neither. An unknown name prints the waitlists there are and exits `1` without joining |
| `--json` | `false` | The coordinator's answer as JSON, times in ISO 8601: `{"data": [...]}` without a name, else the waitlist's entry the join answered |
| `--config`, `-c` | the default `provider.toml` | Which coordinator to ask (`[coordinator] url`) |

```text
Clusters (cluster): not joined
  Serve one model with two to four of your Macs.

Darkbloom Sandbox (sandbox): #3 in line (joined Oct 29, 2026)
  Run Darkbloom Sandbox CI jobs on your Mac.

Join one: darkbloom waitlist <name>
```

| Status | Shown |
|---|---|
| `none` | Not on the waitlist, and the command that joins it |
| `waitlisted` | `#<n> in line` and the day it joined; Darkbloom reviews accounts in the order they joined |
| `approved` | Approved since the day of the decision, and the waitlist's `start_command` when it has one; a leading `darkbloom` becomes the installed command, such as `darkbloom-dev` |
| `revoked` | Revoked on the day of the decision; joining again does not restore it |

A waitlist's entry is
`{feature, title, summary?, start_command?, status, position?, requested_at?, decided_at?}`;
other fields are ignored, and `--json` leaves them out.
Every sentence names the waitlist by its `title`; an entry without one is
unreadable. A control, format or line-separator character in the
coordinator's text (a title, summary, start command or refusal message, such
as an escape sequence or a bidirectional override) prints as `�`, and
`--json` writes it as a `\u` escape, so that text cannot drive the terminal.
The list makes one `GET /v1/waitlists` call; `darkbloom waitlist <name>` reads
the list to find the waitlist, then sends `POST /v1/waitlists/{feature}` with
the body `{}`: no chip, memory or Mac count.
The requests go to the coordinator of `provider.toml` with the token of
`darkbloom login` as a Bearer credential. Only an `https` coordinator, or plain
`http` to this Mac's loopback, is asked; no redirect is followed, a call ends
after 10 seconds and an answer over 64 KiB is refused. When the coordinator
answers `401` (no token, or one it does not take), the command says to run
`darkbloom login` and exits `1`; a `403` says the coordinator refused the
account and to run `darkbloom login` again, and exits `1`. A coordinator without waitlists answers `404`,
with or without a token: the command says there is nothing to join there and
exits `1`. Another status exits `1` with that status and its message; an
unreadable answer, or none at all, exits `1` with the reason.
[Darkbloom Sandbox setup](#setup) requires an approved `sandbox` entry, and a
new pair of [`darkbloom cluster`](#the-cluster-waitlist-gate) an approved
`cluster` entry.

### The cluster waitlist gate

`darkbloom cluster` on a Mac that holds no pairing asks the coordinator of `provider.toml` whether Darkbloom approved this
account from the `cluster` waitlist (`GET /v1/waitlists/cluster` with the
`darkbloom login` token) before the setup screen opens, with the outcomes of the
[sandbox setup gate](#setup): approved goes on; a coordinator without the
waitlist (`404`) prints `<coordinator> has no Clusters waitlist; going on.` and
goes on; not on the waitlist asks `Join the Clusters waitlist now? [y/N]` (no
prints `Join it: darkbloom waitlist cluster`); waitlisted, revoked, `401`,
`403` and no usable answer say why and exit `1` with nothing set up; every
such stop ends with `Serving on your own Macs only needs no approval:
darkbloom cluster local`. The waitlist gates clustering through Darkbloom only:
`darkbloom cluster local` serves on the owner's own Macs, is never asked and
makes no waitlist call, so it works offline. A Mac that
holds a pairing, or one whose pairing can't be read, is never asked and makes no
waitlist call: a pair set up before the waitlist, or serving now, keeps working
across updates and restarts, and `darkbloom start`, `stop`, `restart`,
`status`, the cluster service, **Start over** and **Pair again** are unchanged
(`provider-swift/Sources/darkbloom/ClusterSetupWizardCommand.swift`,
`Cluster.Setup.requireNewPairApproval`).

## `darkbloom stop`

Drain accepted requests and their terminal usage before persistently stopping
the launchd service.

```bash
darkbloom stop [--timeout <seconds>] [--force] [--uninstall] [--solo]
```

| Flag | Type / valid range | Default | Effect |
|---|---|---|---|
| `--timeout <seconds>` | integer, 0–3600 | `600` | Wait for accepted coordinator requests, local response writes and the coordinator acknowledgement |
| `--force` | flag | `false` | Explicitly permit bounded cancellation and termination of unfinished work |
| `--uninstall` | flag | `false` | After draining or explicit force, remove the provider and watchdog plists and boot out and remove the desktop API agent (`io.darkbloom.desktop-api`, best effort). Every file, the cluster service and the pairing stay; [`darkbloom uninstall`](#darkbloom-uninstall) takes Darkbloom off the Mac |

The command disarms the watchdog and disables login/reboot startup before
requesting the drain. If setup fails before the mailbox request is published,
it restores the prior launchd/watchdog recovery state and retains its history. A normal drain timeout returns non-success and leaves the
process draining with automatic restart disabled. Repeat `stop` or `restart`
with a new deadline, or explicitly pass `--force`. Interrupting the CLI does not
cancel accepted inference or reopen admission. A running provider without the
drain control protocol requires an upgrade or an explicit forced interruption.

On a Mac in a two-Mac cluster, `stop` stops the pair on both Macs, the same as
`darkbloom cluster stop` (`Stop.pairedStop`, `ClusterPairCommands.stop`): the
leading Mac drains and stops both Macs' parts, as Stop in `darkbloom cluster`
does, and the Mac that follows asks it to. The pair is saved as stopped, so
neither Mac serves it again at login or after a restart; both cluster services
stay up, idle with nothing loaded, so `darkbloom start` on either Mac starts the
pair again. It waits up to a minute until both Macs' parts have ended (each
Mac's memory check, `cluster verify-teardown`), then says so:

```text
This Mac is in a two-Mac cluster with the other Mac (Apple M5 Max, 128 GB): stopping both Macs.
Stopped on both Macs. They stay stopped after a restart; `darkbloom start` on either Mac starts the pair again.
Memory freed on both Macs ✓
```

A wait that runs on says what it waits for and how long at most: `Waiting for
both Macs to stop; accepted requests finish first (up to about 6 min).` while
the leading Mac drains (after 3 seconds; `cluster stop --service` too), and
`Waiting for both Macs' parts to end (up to 1 min).` while the parts end
(`restart`: up to 5 minutes).

These waits, the 10-minute wait of `start` on a pair, and the earnings
windows of the desktop app (7 days, 30 days and the last 24 hours) compare
times with `timeIntervalSince(_:)`. They do not use Date `>=` or `<=`. SDK 27.2
back-deploys those two operators as weak Foundation imports. Pre-release
macOS 27.2 builds (for example 26B5091g) do not export them, and a call through
one crashed the provider in a loop. The limits and results stay the same.
`scripts/check-date-comparisons.py` refuses the pattern in source, and the
release build refuses a binary that imports either symbol
(`scripts/check-provider-weak-imports.py`). The
[build guide](../developer/build.md#sdk-27-release-builds-and-caches) tells how
to fix a hit.

If a part hasn't ended by then, it says ``Asked both Macs to stop; they stay stopped after a restart, and `darkbloom start` on either Mac starts the pair again.``
and what each Mac has left (or `Memory: not checked (…)` when the check didn't
answer), exit 1. On the Mac that follows, the stop always goes to the leading
Mac. When that Mac never got it (refused, unreachable), nothing is stopped: it
names the Mac and says how to stop this Mac alone
(`darkbloom cluster stop --local-only`), exit 1. When it timed out, the leading
Mac may still be finishing, and `darkbloom status` shows where both stand; when
it answered with its own reason, that reason is shown
(`ClusterPairSummary.memberStopFailureLines`). When this Mac's cluster can't be
reached from the command, it says
``This Mac's cluster can't be reached from this command; run `darkbloom cluster` on this Mac to see it.``
(exit 1). `darkbloom cluster stop` refuses the same way as `stop` when this
Mac's pairing record can't be read, and points to `--service` to stop this
Mac's cluster service anyway (`Cluster.Stop.refusal`). After
`darkbloom cluster stop --local-only` it says to run
`darkbloom cluster stop --service` on the other Mac if it comes back.
`stop --solo` (and `--uninstall`) stops single-Mac serving on this Mac only and
never touches the pair; a daemon state the cluster's part wrote is never drained
(`ServiceDrain.soloProviderState`).

While the pair doesn't run here (`Stop.PairedStop.stopHere`), plain `stop` stops
what runs on this Mac: a leftover part of the pair (its saved start on this Mac
is cleared) and single-Mac serving. It never asks the other Mac. It takes the
cluster command lock first, as `darkbloom cluster stop` does (waiting up to 10
minutes for a cluster command that is running, and saying so at once, as
`start` does), so no automatic step of the cluster service starts the pair
again after it. While the
other Mac answers but the pair hasn't served yet, plain `stop` stops the pair
on both Macs, as while it runs.

Code: `provider-swift/Sources/darkbloom/ServiceDrain.swift` (`DrainOptions`,
`ServiceDrain.prepare`) and `provider-swift/Sources/darkbloom/StopCommand.swift`
(`Stop`). See [graceful lifecycle behavior](#graceful-stop-and-restart) for signal
handling and launchd's termination allowance.

## `darkbloom uninstall`

Take Darkbloom off this Mac. In a terminal with no flags it shows two choices
with this Mac's sizes and reads one key:

```text
Uninstall Darkbloom from this Mac

  1) Remove everything
     The app, settings, pairing, logs and all models · frees 412 GB
  2) Keep models
     Removes everything else; a reinstall reuses the 410 GB of models

  Choose 1 or 2 (Esc cancels):
```

The sizes are measured on this Mac. APFS clones (the cluster model store clones
the downloaded models) count once, and blocks a clone outside Darkbloom's
folders still uses are not counted. Each choice's line says what it removes on
this Mac (`ProviderUninstall.everythingRemoves`): no pairing while another install
shares it, and "all models" only when no model stays. Lines under the choices
appear only when this Mac has folders no choice deletes, or Darkbloom parts with
their own uninstall.

**1** asks once more, and only `y` or `yes` goes on; anything else changes
nothing (`ProviderUninstall.everythingQuestion`). **2** asks nothing more.

```text
  Remove everything, including 410 GB of models? This can't be undone. [y/N]:
```

Run as root (`sudo`), every form of the command, `--dry-run` included, prints
this and exits 64 before it lists or changes anything
(`ProviderUninstall.rootRefusal`):

```text
Run `darkbloom uninstall` as yourself, not with sudo: it removes your own Darkbloom, and asks for your password when a step needs it.
```

```bash
darkbloom uninstall                            # the screen: 1, 2 or Esc
darkbloom uninstall --keep-models --dry-run    # every action and path, with sizes; changes nothing
darkbloom uninstall --keep-models --yes        # a reinstall reuses the models
darkbloom uninstall --everything --yes         # nothing left behind
```

| Flag | Type | Default | Effect |
|---|---|---|---|
| `--everything` | flag | `false` | Remove everything: the app, settings, pairing, logs and all models |
| `--keep-models` | flag | `false` | Remove everything but the models, so a reinstall reuses them |
| `--yes`, `-y` | flag | `false` | Don't ask for confirmation |
| `--dry-run` | flag | `false` | List every action and path with sizes, and change nothing. Without a mode it lists both |
| `--json` | flag | `false` | With `--dry-run`: the plan as JSON (`darkbloom_uninstall_plan_v1`) |
| `--timeout`, `--force` | | | The [stop](#darkbloom-stop) drain options |

Without a terminal, a mode and `--yes` are required; otherwise the command
prints `Usage: darkbloom uninstall --everything|--keep-models [--yes] [--dry-run [--json]] (no terminal to ask which)`
and exits 64. Both modes together, `--json` without `--dry-run`, or an unknown
flag are refused with the usage before anything runs.

**The steps, in order, the same for both choices.** Each is idempotent; the
summary lists each one as `done`, `skipped` or `failed`, with the reason, and the
command exits 1 when one failed or when a folder of Darkbloom's was not removed.
A failed step does not stop the safe steps after it.

| # | Step | Through | Skipped when |
|---|---|---|---|
| 1 | Stop serving on this Mac | the [stop](#darkbloom-stop) drain (`ServiceDrain`) | the provider service was not running. When a cluster service serves here instead, the step says whose (step 2 handles it) |
| 2 | Stop this Mac's cluster part and remove its service | `darkbloom cluster stop --service`; when the other Mac does not answer, `cluster stop --local-only`. It stops a running cluster service whose command is `darkbloom cluster service`, launchd's or one a session started, wherever it runs from, even outside this install's app (`ClusterService.stopDetached`), and removes this install's own login agents only (`ClusterServiceAgent.installedLabels`, `ClusterServiceAgentPlan.isOwnAgent`). Each install has its own pair, service lock and agent, so another install's pair and agent are never touched. A service under another command name is not stopped: this step fails with that stop's own message, and nothing is deleted. Anything else holding the lock is refused, and nothing is deleted: a service from neither app, a pid that is no cluster service, or a lock or pid file that can't be read. Whose a service is follows its executable with links resolved (`ProviderUninstall.owner`) | no cluster service on this Mac. The dry run says what this step does to a cluster service running here (`ClusterService.running`) |
| 3–5 | Remove the provider, watchdog and desktop API launch agents | what `stop --uninstall` runs (`LaunchAgent.uninstall`, `WatchdogAgent.uninstall`, `DesktopService.uninstall`) | not installed, or serving did not stop in step 1 |
| 6 | Revoke this Mac's account token, best effort | what `darkbloom logout` does (`Logout.revokeSavedToken`) | no saved token, the coordinator did not confirm it, or serving did not stop. It never fails the uninstall; the token file goes with `~/.darkbloom` |
| 7 | Forget the pairing with the other Mac | `darkbloom cluster pair --forget <pin>`, once per pairing of this install | this Mac is not paired |
| 8 | Undo the cable port setup | `darkbloom cluster link --remove` (macOS asks for an administrator's password) | nothing to undo, or another install is on this Mac, which may use the same cable (below) |
| 9 | Delete Darkbloom's folders, one step each (table below) | | already gone, refused (`not removed: <why>`), or a service did not stop in steps 1–5. Right before the first deletion, after steps 3–8, the run reads the cluster service lock again (its lock, its pid file, the process's executable and arguments): while a cluster service of this install, or one it can't tell apart, holds it, nothing is deleted, the summary says `Stop it first with darkbloom cluster stop --service, then run darkbloom uninstall again`, and the command exits 1. When step 8 did not complete, `~/.darkbloom` and the command link stay, so the command can run again |

**What is deleted**, from `ProviderUninstallPaths` and `ProviderUninstall.inventory`
in `provider-swift/Sources/ProviderCore/Service/Uninstall/ProviderUninstallPlan.swift`:

| Item | Path | 1) Remove everything | 2) Keep models |
|---|---|---|---|
| Settings | `~/.config/darkbloom` (`provider.toml`, saved cluster setups) | deleted | deleted |
| Encrypted prompt caches | `~/Library/Caches/darkbloom` | deleted | deleted |
| Each model Darkbloom downloaded | `~/.cache/huggingface/hub/models--<org>--<name>`, only folders holding Darkbloom's receipt (`.darkbloom-manifest.json`) or its unfinished download (`.local-staging-*`), and `.artifact-writer-locks` | deleted | kept, with their `refs/` and receipts, so a reinstall's scan finds them |
| Cluster model store | `~/.cache/huggingface/darkbloom-cluster-models` | deleted | kept |
| The command link | `/usr/local/bin/darkbloom`, only while it links to `~/.darkbloom/bin/darkbloom` | deleted | deleted |
| Darkbloom folder | `~/.darkbloom`: the app, `bin/`, logs, this install's pairing, account token, cluster setup and service state. Last, since the command runs from the app in it. When a models folder you chose is inside it, everything else in it is deleted, the app last | deleted | deleted |

What no choice deletes (the summary lists them):

- anything that resolves outside those folders. A target that is a link, or
  whose resolved path is elsewhere, is refused and reported, and a link inside a
  deleted folder is removed without following it. A folder that is another
  disk's mount point, or holds one, is refused too;
- a models folder you chose (`[backend] model_cache_directory`, set by
  `darkbloom models location`) and the cluster model store beside it
  (`darkbloom-cluster-models` in the same parent folder), in both choices and
  wherever they are. Inside Darkbloom's folders (for example
  `~/.darkbloom/models`) they stay with the folders that lead to them, and the
  screen, the dry run and the summary list them as `Kept:`; elsewhere, as
  `Never touched:`. After a reinstall, `darkbloom models location <folder>` uses
  the chosen folder again. When the chosen folder is `~/.darkbloom` itself (or
  holds it), the app folder stays with it: the summary's first line says
  Darkbloom is not fully removed because its app folder is your models folder,
  the step says to move the models out and run `~/.darkbloom/bin/darkbloom
  uninstall` again (the settings naming the folder are gone by then, so that run
  deletes the rest), and the command exits 1;
- caches in a folder you chose outside Darkbloom's folders
  (`darkbloom cache set --directory`), the default model cache when it is a
  link, and other tools' models;
- the models and the cluster model store while another Darkbloom install
  (`~/.darkbloom-dev`, `~/.darkbloom-staging`) shares them;
- this Mac's cable port setup while another install is on this Mac: the
  production Darkbloom and Darkbloom Dev (`darkbloom-dev`) may use the same
  cable. The other install counts when its app or `bin/` command is in its
  folder (`ProviderUninstallPaths.otherEnvironment`). Step 8 is skipped
  (`kept: <the other install> on this Mac may use the same cable`). Each
  install keeps its own pairing, cluster setup and cluster service in its own
  folders (`ClusterUserPaths`), so steps 2 and 7 and the deletions take only
  this install's, and the other install's pair keeps serving. The screen, the
  dry run, `--json` and the summary say it, here for `darkbloom-dev uninstall`,
  and the summary's first line names the install it removed (`Darkbloom Dev is
  removed from this Mac.`):

  ```text
  Kept: this Mac's cable port setup: the production Darkbloom on this Mac may use the same cable. Run `darkbloom uninstall` there to undo it
  ```

  The other install's uninstall undoes all of it once that install's
  `cluster` has used the cable on this Mac: it then records a port this
  install set up with what the setup changed, read from this install's link
  record (`ClusterLinkRepair.Environment.otherInstallsIsolationEntries`). An
  install that never used the cable here removes Darkbloom's network service
  from the port; the port's other network services, and its place in Thunderbolt
  Bridge, are then turned back on in System Settings → Network.

- Keychain items (Secure Enclave and App Attest keys); a new install replaces them;
- the fan helper (`sudo darkbloom fan uninstall`), Darkbloom Sandbox
  (`darkbloom sandbox uninstall`), a legacy MDM profile (`darkbloom unenroll`) and
  the shell `PATH` line the installer added.

The summary says what was removed, what was kept and where, and the space freed
(the change in the home volume's free space). When a folder of Darkbloom's was
refused, its step reads `not removed: <why>`, the first line is `Darkbloom is not
fully removed from this Mac: some of its folders were not removed (see below).`
and the command exits 1. A command link the installer did not make is reported
the same way but is not Darkbloom's, so it alone does not count. After **Keep models** it ends with
the way back: the install command, then `darkbloom start` or `darkbloom cluster`;
the models are found automatically. On a paired Mac its last line names the other
Mac: run `darkbloom uninstall` there too, or `darkbloom cluster` on it to pair it
with another Mac.

Code: `provider-swift/Sources/darkbloom/UninstallCommand.swift` (`Uninstall`) and
`provider-swift/Sources/ProviderCore/Service/Uninstall/ProviderUninstall.swift`
(`ProviderUninstall.run`).

## `darkbloom restart`

Drain accepted work, reload the recorded launchd configuration, and confirm a
new provider process with fresh serving authorization. The coordinator URL,
model selection and provider config arguments are preserved.

```bash
darkbloom restart [--timeout <seconds>] [--force] [--startup-timeout <seconds>] [--config <path>]
```

| Flag | Type / valid range | Default | Effect |
|---|---|---|---|
| `--timeout <seconds>` | integer, 0–3600 | `600` | Wait for accepted work and the coordinator acknowledgement before restarting |
| `--force` | flag | `false` | Explicitly permit interruption of unfinished work before restarting |
| `--startup-timeout <seconds>` | integer, 1–3600 | `180` | Wait for a new process identity and fresh App Attest, legacy, or owner self-route authorization |
| `--config <path>` | path | unset | Override the config used to re-arm the watchdog; the provider keeps its recorded config arguments |
| `--solo` | flag | `false` | On a Mac in a two-Mac cluster: restart single-Mac serving on this Mac only |

On a Mac in a two-Mac cluster, `restart` restarts the pair: it stops serving on
both Macs, starts the current model again, waits until it serves, and ends with
the same result block and exit status as `start` without a terminal
(`Restart.pairRestart`, `ClusterPairCommands.restart`). `--solo` restarts
single-Mac serving on this Mac only. While the pair doesn't run here (stopped,
or the other Mac isn't answering), plain `restart` never starts the
pair: it restarts single-Mac serving that runs here, its launchd job loaded
(after stopping a leftover part of the pair). Single-Mac serving that `stop`
stopped keeps its plist on disk, but plain `restart` doesn't start it. With none
running, it restarts nothing, exit 1, and says `darkbloom start` starts the pair
again and `darkbloom start --solo` serves this Mac alone
(`ClusterPairSummary.idleRestartRefusal`). Before it restarts single-Mac serving
there it stops a started pair's leftover part, saying so before and after, as
`start --solo` does (`Start.releaseLeftoverPartToServeAlone`). After it restarts
single-Mac serving there, or after `--solo` there, it says ``The pair was not
started; `darkbloom start` starts it.`` (`ClusterPairSummary.restartRestartsPair`). A started pair there is named as
not running: ``This Mac is in a two-Mac cluster with the other Mac (…), which
isn't running here (the other Mac (…) isn't answering).``, without the
parenthesis while this Mac's cluster service is down, never "This Mac serves".

A drain timeout returns non-success and leaves the old process draining with
automatic restart disabled; repeat the command with a new deadline or explicitly
choose `--force`. A startup timeout returns non-success while the new service
keeps starting, without issuing another restart. Inspect `darkbloom status` to
check its progress. An installed, stopped service is started (on a Mac in a
two-Mac cluster, only with `--solo`); a missing service returns non-success.
The watchdog is re-armed according to `provider.auto_restart`.
A foreground/local process is explicitly terminated after draining before the
saved launchd configuration starts. If no launchd configuration exists, restart
refuses before disturbing that process; use `start` to choose a replacement.
Owner-only/preferred-owner connections may confirm `self_route` authorization;
this does not claim public-fleet eligibility.

Code: `provider-swift/Sources/darkbloom/ServiceDrain.swift` (`DrainOptions`,
`ServiceDrain.waitForRestart`) and
`provider-swift/Sources/darkbloom/RestartCommand.swift` (`Restart`).

## `darkbloom status`

Show local configuration, hardware, schedule, and live daemon state.

```bash
darkbloom status [--solo]
```

On a Mac in a two-Mac cluster, `status` starts with the pair in the words of
`darkbloom cluster status` (who leads, the model, whether it serves now and what
to do; on the Mac that follows, the leading Mac is asked over the cable), then
this Mac's configuration and hardware. The pair and single-Mac serving share
the Mac's one serving lock, so a paired Mac serves one or the other. When it
serves alone (`start --solo`), a line under the pair block says so plainly
(``This Mac serves alone (single-Mac serving, process <N>), not the pair; its
status is below.``, `Status.servingAloneLine`), and single-Mac serving's own
`Daemon:`, `Serving:`, `Trust:` and traffic lines follow, as `status --solo`
shows them. Otherwise those lines, which would be the cluster's own part's, are
left out. `status --solo` shows single-Mac serving instead of the pair, with the
pair in one `Cluster:` line (`ClusterPairSummary.statusLine`). `darkbloom status` exits 0;
`darkbloom cluster status` gives the same pair block with `--json` and exit
statuses for scripts. `darkbloom doctor` prints the same `Cluster:` line under
its `Daemon:` line, which reads `Daemon: single-Mac serving off (this Mac serves in its two-Mac cluster)`
when no provider runs (`Doctor.daemonLine`).

Output includes:

- Provider version and config path.
- Coordinator URL and backend settings.
- Startup preload on/off, whether the explicit list or selected models drive
  it, and the registration timeout.
- Detected hardware (chip, RAM, GPU cores).
- `Inference memory` is the nominal hardware budget, **not** live free RAM.
- Schedule state (active/inactive).
- Live daemon PID, uptime, trust verdict, and last model-load error with how
  long ago it was recorded (`Recorded … ago`); the readiness lines above it are
  live. A refusal that could not evict a resident model ends with
  `Not evictable: …`, naming each such model with its resident GB and every
  reason ([load gate](../architecture/hardware-support.md#load-gate-modelloadadmission)). A
  GLM-5.3-Flash error that reports a Metal command buffer out of memory adds
  the `→ fix:` line from
  [GLM-5.3-Flash GPU wired-memory limit](#glm-53-flash-gpu-wired-memory-limit).
- App Attest serving authorization can remain visible through its unexpired lease, while MDM removal advice requires a matching fresh coordinator decision. The same distinction applies to both doctor summaries; see [provider authorization](../reference/provider-authorization.md).
- `Requests served since the daemon started (… ago)`: coordinator requests
  this daemon finished since it started, with output tokens only. The count
  restarts at zero when the daemon restarts or a scheduled availability window
  opens. It includes requests that ended early on a coordinator cancel or a
  dropped connection after output had been delivered (the next line counts
  them when there are any; the coordinator may not pay for them) and free
  [self-route](./self-route.md) requests to your own machine. Paid jobs are on
  the console's Earnings page; the console's machine card adds these counters
  up across restarts
  ([coordinator/registry/heartbeat.go](https://github.com/Layr-Labs/darkbloom-platform/blob/10b8b4fabad60e20961b1b74a8672be41c5a0a2d/coordinator/registry/heartbeat.go),
  `cumulativeDelta`)
  (`provider-swift/Sources/darkbloom/StatusCommand+ServedRequests.swift`).
- `Enabled model filter` is the saved config; a running daemon applies a
  changed `enabled_models` only at its next start. `Serving outside the enabled
  model filter` names each warm or advertised model the filter omits and why it
  serves: an Autopilot operation's adoption, the running daemon's selection, or
  the live Autopilot lease. `Autopilot placements` lists adoptions and placement
  holds with each hold's UTC expiry and time left. `Not evictable for a load
  now` lists the resident models no load can evict at the snapshot, with the
  same reasons a refusal gives (`provider-swift/Sources/darkbloom/StatusCommand+Residency.swift`).
- `Traffic:` whether the coordinator can route work to this connection, judged
  from current evidence only; the provider re-registers on the same verdict.
  `eligible for coordinator work` names the App Attest lease or legacy
  verification, or a request the coordinator routed after its latest status
  (`received a coordinator request … ago`; state field
  `coordinator_connection.last_request_at`). `not yet eligible` covers the first
  90 seconds after connecting (`statusGraceSeconds`) while the coordinator has
  sent no status or one that does not authorize the connection yet.
  `NOT receiving coordinator work:` names the cause with a `→ fix:` line:
  disconnected, with how long the connection has been down across failed
  reconnect attempts; no coordinator status 90 seconds after connecting; an
  `untrusted` or `offline` status; an expired lease; or a refusal received in the
  last 60 seconds (`refusalMaxAge`) with the coordinator's reason, such as a
  locked login keychain, a stalled Apple call, App Attest unavailable on macOS 26
  or outside a logged-in GUI session, or a connection without a linked account.
  An older refusal reads `unconfirmed`, with its age and reason and no fix: the
  current coordinator sends no status when legacy verification authorizes a
  connection after the refusal it sends at registration. Omitted while a drain line
  is shown, while an add-on holds a connected Mac (its
  `Not serving: held by add-on` line says why no work arrives), for a stale
  snapshot, and for daemons that predate the `coordinator_connection` state field
  (`provider-swift/Sources/ProviderCore/Diagnostics/ServingReadiness.swift`,
  `provider-swift/Sources/darkbloom/StatusCommand+Traffic.swift`).
- `Not serving:` when the daemon is alive but a graceful drain has closed
  admission — draining, a drain that did not finish, or a drain whose relaunch
  never happened — with the commands that finish or interrupt it
  (`provider-swift/Sources/darkbloom/StatusCommand+LifecycleDrain.swift`,
  `Status.lifecycleDrainLine`).
- `Sandboxes:` after `Serving concurrency`, while the
  [Darkbloom Sandbox](#darkbloom-sandbox) add-on is installed: its state, the
  jobs running and the free slots (`Sandboxes: running 1 job; free slots Linux
  0/1, macOS 1/1`), or why it could not answer. Nothing without the add-on. The
  query starts with the command and gives up after 2 seconds, so the add-on
  never fails `status` (`provider-swift/Sources/darkbloom/Sandbox/SandboxStatusView.swift`,
  `SandboxStatusView.statusLine`).
- `Memory when idle`: the idle-memory policy in force (`always ready` or
  `free after N idle`). Advertised models without a resident engine are
  separated into `Startup preload pending`, `Not loaded (loads on request)`,
  `Preload skipped (no eviction)`, and `Cold load blocked (memory)`. A fresh daemon snapshot reports the no-eviction
  usable load memory beside a blocked model's scanner estimate, activation +
  minimum-KV serving reserve, required total and no-eviction shortfall. When
  request-time eviction still cannot fit the model, the cold-load shortfall
  (the amount to free) is shown separately. Older or stale snapshots and
  snapshots taken during active or queued requests, a model load or a reload withhold a
  definitive verdict. The daemon writes the load transition during startup
  preload even before its first backend-capacity snapshot.
  `always ready`
  retains loaded models but does not override the memory load gate.
  An eviction-aware allowance distinguishes a preload that preserves resident
  models from a cold request that can evict idle slots; only the latter earns
  the `Cold load blocked` label when it still cannot fit.
  A memory skip also writes a fixed public category to `darkbloom logs`; model
  loads refused at final admission, allocation recheck, or measured post-load
  KV headroom, or fleet KV re-slice serviceability use the same warning.
  Model names and exact load figures remain private there and appear in the owner's
  live `status` and `doctor` output instead.
- Per-slot posture: the KV backend each loaded model actually resolved to
  (`paged` / `contiguous`), the selection the config asked for, whether
  MTP is enabled, active, or enabled-but-inert, and the SSD prefix cache's
  status (`prefix_cache=`).

### Slot posture

```
Slot posture: state written 2s ago
  google/gemma-4-26b: kv=paged (requested paged) | mtp=enabled, active | … | prefix_cache=ready
  openai/gpt-oss-20b: kv=contiguous (requested auto) | mtp=enabled but INERT (inert_kv_unsupported)
  qwen3.5-35b-a3b: kv=paged (requested auto) | mtp=enabled, active | … | prefix_cache=FAILED (cache_init_failed: key_unavailable)
    → prefix cache: its encryption key could not be loaded from the Secure Enclave and Keychain
    → fix: run the signed release (`darkbloom update`); …
  big/model-70b: kv=NOT SERVING (requested paged) — load failed: …
```

`requested` is what `engine_v2_kv_backend` (or a per-model override in
`engine_v2_kv_backend_by_model`) asked for; the `kv=` value is what the
engine was actually built with. They differ when a request was vetoed,
degraded, or refused — an explicitly requested `paged` backend that cannot
be built REFUSES the load rather than serving contiguous, so that model
shows `kv=NOT SERVING`.

`mtp=enabled but INERT` means a drafter is resident and charging memory
while producing no drafts. It is not the same state as `mtp=enabled,
active`, and the reason is always named.

`prefix_cache=` is the slot's SSD prefix-cache status as the heartbeat reports
it: `ready`, `starting`, `off (<reason>)` for a model or slot that does not
cache by design, `closed (unloading)`, or `FAILED (<reason>: <cause>)` with the
cause and fix on the next lines. A failed cache serves the model uncached and is
built again when the model next loads. `doctor` reports the same failure as a
`prefix cache` check; the desktop app's diagnostics run `doctor`
(`PrefixCacheDiagnosis`,
`provider-swift/Sources/ProviderCore/Diagnostics/PrefixCacheDiagnosis.swift`).
Causes are listed in the
[SSD KV cache reference](../reference/ssd-kv-cache.md#status-and-outcome-vocabularies).

These values come from the daemon's state file
(`~/.darkbloom/daemon-state.json`, override with `DARKBLOOM_STATE_FILE`),
which the running daemon rewrites every `heartbeat_interval_secs / 2`
seconds — about every 2 s at the default. The header carries the snapshot's
age, and the block is prefixed `STALE` once it has gone unrefreshed for
four write cycles: a value from before a reload is worse than no value.

## `darkbloom doctor`

Run local diagnostics and fetch the coordinator's trust view.

```bash
darkbloom doctor [--strict] [--coordinator <url>] [--support] [--clear-backend-guard] [--hardware]
```

| Flag | Description |
|------|-------------|
| `--strict` | Treat warnings as failures |
| `--coordinator <url>` | Override coordinator URL for remote checks |
| `--support` | Print local identifiers useful for support |
| `--clear-backend-guard` | Remove the crash-loop KV guard, reset its restart chain and exit; normal selection resumes on the next load |
| `--hardware` | Print one whole-machine load sample and which counters this Mac exposes, as JSON ([format](../reference/desktop-control.md#hardware-load)), and exit |

The report header prints `Build` (`prod` or `dev`, fixed at compile time),
`Coordinator` (the `--coordinator` value, else `[coordinator] url`) and
`Model CDN` (`DARKBLOOM_R2_CDN_URL` from the shell, else the build default).
`Model CDN` does not read the LaunchAgent plist.

`darkbloom doctor` is read-only except for the subprocess calls used by public
ProviderCore checks and the explicit `--clear-backend-guard` action
(`provider-swift/Sources/darkbloom/DoctorCommand.swift`, `runClearBackendGuard`).
On a Mac paired for a two-Mac cluster, the detailed checks also list the
checks `darkbloom cluster doctor` runs (installed metadata, trust files, the
Thunderbolt RDMA link, the saved setup), each named `cluster <check>`; a failed
one fails the run and points to `darkbloom cluster doctor` for its details. The
saved-setup check counts a provider configuration that other users can open
(the installer writes it so for a coordinator other than production's) as no
saved setup until a setup is saved, which makes the file private; one that
saves a setup fails with the fix, `chmod 600 <file>`
(`ClusterConfigurationStore.optionalInstalledReference`). A
Mac that is not paired gets none of them, and its link is not inspected
(`provider-swift/Sources/darkbloom/DoctorClusterChecks.swift`,
`buildClusterDoctorChecks`). On a Mac that serves its share of a cluster's
model, **model fits in RAM** says the single-Mac load check does not apply
and points to `darkbloom cluster doctor`, instead of weighing the whole model
against this Mac's memory (`ModelFitDiagnostic.clusterMember`).
The operator report begins with a readiness summary and the first concrete
action. A failed model-fit check names the live usable memory, the required
load budget and their shortfall; it tells the operator to free memory, rerun
`doctor` and restart to retry preload when enabled. Interactive terminals color section
headings and PASS/WARN/FAIL markers. Every advertised cold model is checked,
largest first, so a small fit cannot hide a larger model's failure.
Pipes, `NO_COLOR`, `CLICOLOR=0`, and
`TERM=dumb` retain plain text.
When the daemon's capacity snapshot is fresh, `doctor` uses its paired
no-eviction usable memory and serving headroom sample; otherwise it falls back to a local read-only memory
sample and does not claim to know the earlier startup decision.
An already resident target is reported as resident without pretending it needs another cold
load. When the fresh daemon reports that idle eviction could fit a cold model,
`doctor` warns about no-eviction preload instead of claiming request-time
loading is impossible. On a multi-model Mac, a selected cold model with a
recent load failure is diagnosed before an unrelated recently used resident
model, so the model-fit line explains the failure the operator came to check.

Two of the detailed checks cover the KV-backend rollout:

| Check | Fails when |
|-------|-----------|
| `daemon state freshness` | The daemon is running but has not rewritten its state file for eight write periods — it is wedged, and every live value below it is a guess. The bar is derived from `heartbeat_interval_secs` (the daemon writes every half-heartbeat) with a 90 s floor, so raising the heartbeat does not make a healthy daemon look wedged. |
| `kv backend posture` | An EXPLICIT `paged` or `contiguous` request was not honoured: refused (no engine built, the box serves nothing for that model) or silently degraded to another backend. |

The posture check compares explicit live-backend requests; an `auto` slot does
not fail this check. Native live precision is the default and keeps the
model-specific automatic backend policy. Explicit non-MiMo live `balanced`,
`k8v4` and `k8v8` `auto` require paged even outside the
[exact qualified-artifact cohort](../architecture/prefix-cache.md#kv-layouts),
and refuse construction if a veto or failure resolves contiguous. Native
`auto` retains its observable contiguous fallback; native precision can also
use explicit `paged`. Checkpoint compression never selects the live backend.
MiMo resolves both precision choices to `native` before overrides and keeps its
native backend path (`EngineV2KVQuantizationPolicy.resolve`,
`provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVQuantizationPolicy.swift`).

Current slot diagnostics add `live_kv`, `checkpoint_kv` and, for an active
complete store, `layout`. These are effective bridge/store values, not requested
settings. `checkpoint_kv=off` means no complete store is active in a current
snapshot; an older snapshot with no live precision field makes no precision
claim (`DaemonState.SlotPosture`, `KVBackendPosture.precisionPhrase`). The
same posture is shown by `status` and `doctor`; it is not a new heartbeat field.

For a guarded automatic AR paged retry, use
`darkbloom doctor --clear-backend-guard` before retrying construction; direct
Diffusion assembly does not consult this crash-loop guard. For explicit contiguous recovery, resolve
`native` precision before selecting `contiguous` or disabling paged storage
with `DARKBLOOM_CBV2_PAGED_KV=0`; see the
[precision settings](#providertoml-keys-read-by-the-cli).
`DARKBLOOM_CBV2_PAGED_KV=0` also fails the Nemotron Super load, which serves
paged KV only and ignores `engine_v2_kv_backend`
([configuration reference](../reference/configuration.md#engine-and-scheduler)).
A posture pass alone
does not qualify precision or the runtime. Explicit `paged` construction
failures refuse the load; a native policy veto that serves contiguous still
fails the explicit-request check (`KVBackendPosture.backendCheck`,
`provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift`). When the
state file is past the wedge bar the backend verdict is WITHHELD rather than
asserted from a snapshot that may predate a reload.

An explicit `engine_v2_kv_backend` with no slot behind it — startup preload
off, or every slot idle-unloaded — WARNs rather than passes: nothing on the
box has loaded, let alone proved, the backend it was configured for. Under
`--strict` (and therefore `darkbloom verify`) that warning exits non-zero,
which is the point: an unproven paged rollout must not certify.

### GLM-5.3-Flash GPU wired-memory limit

On a 256 GB M5 Mac where GLM-5.3-Flash is downloaded, named in `[backend]`
`model`, `enabled_models` or `preload_models`, or served by the daemon, `doctor`
adds the `glm wired limit` detailed check. It compares `iogpu.wired_limit_mb`
(Metal's recommended working set while it is `0`, the macOS default),
`vm.global_user_wire_limit` and `vm.user_wire_limit` with the
[production values](./hardware-requirements.md). Below them it is ⚠, never ✗:
the detail gives the planned full-KV GPU memory and the
`sudo sysctl -w …` fix, and a `GLM-5.3-FLASH GPU WIRED-MEMORY LIMIT — ACTION
RECOMMENDED` block after the detailed checks prints the current values, the
fix, `darkbloom restart` and the copy-paste LaunchDaemon install (`sudo tee`
heredoc, then `sudo launchctl bootstrap system …`). At or above them it is ✓
with the current values. Other Macs, sizes and model sets show no line, and
`darkbloom verify` does not run the check
(`provider-swift/Sources/darkbloom/Diagnostics/GLMWiredLimitAdvice.swift`,
`GLMWiredLimitAdvice.doctorCheck`).

The same one-line fix also appears:

| Where | When | Source |
|---|---|---|
| `darkbloom start` stderr, as `warning: …` | The selection would serve GLM-5.3-Flash below the values; start continues | `GLMWiredLimitAdvice.startNotice` |
| `darkbloom status`, as `→ fix: …` under `Last model-load error` | The recorded GLM-5.3-Flash load error reports a Metal command buffer out of memory and the values are still low | `GLMWiredLimitAdvice.statusNotice` |
| Daemon stderr (`~/.darkbloom/provider.log`; the terminal of `start --local` or `--foreground`), plus the fixed `darkbloom logs` line `GLM-5.3-Flash hit the macOS GPU wired-memory limit. Run darkbloom doctor for the fix.` | Once per process, when a GLM-5.3-Flash load, startup preload, self-test or coordinator request fails with that error and the values are still low | `provider-swift/Sources/ProviderCore/Diagnostics/GLM5NextWiredLimitNotice.swift` (`GLM5NextWiredLimitNotice`) |

The error text is only matched, never logged. Failures the native engine
reports without the MLX error text cannot be matched; `doctor` and `start`
still flag the limit. None of these change admission, KV grants or capacity.
Steps: [troubleshooting](./troubleshooting.md#glm-53-flash-gpu-wired-memory-limit).

## `darkbloom verify`

Equivalent to a strict `doctor` run. Any warning or failure exits non-zero.

```bash
darkbloom verify [--coordinator <url>]
```

## `darkbloom models`

Manage locally cached MLX models.

### `darkbloom models catalog`

Show the coordinator's supported-model catalog.

```bash
darkbloom models catalog [--coordinator <url>] [--json] [--type <type>]
```

### `darkbloom models list`

List local models.

```bash
darkbloom models list [--json] [--all] [--hash <model-id>]
```

| Flag | Description |
|------|-------------|
| `--all` | Show every discovered model, ignoring `enabled_models` |
| `--hash <model-id>` | Compute an on-demand integrity hash for one model |

### `darkbloom models download <id>`

Download a model from the coordinator catalog.

```bash
darkbloom models download <id> [--coordinator <url>] [--r2-cdn <url>]
```

The download shows one progress line for the whole model, not one per file.
Downloads chosen in the `darkbloom start` picker print the same lines. In a
120-column window:

```text
  Downloading EigenLabs/Qwen3.8-27B-4bit-mtp  [███████████░░░░░░░░░░░░░░░]   43%   7.0/16.3 GB   125 MB/s   1m 14s left
```

| Standard output | What is printed |
|---|---|
| A terminal | That line, redrawn in place at most every `TransferProgressLine.redrawInterval` (`0.25` s). Its columns are set once for the window's width (`TransferProgressLine.layout(width:)`): each figure has a column as wide as its widest form for this download (`100%`, the total's bytes, `99.9 GB/s`, `23h 59m left`), right-aligned, so the bar and the figures stay put while the width stays the same. The figures whose columns do not fit are left out. While the files are checked against the manifest it reads `Verifying <id> (<size>)…`; then the last line (below) takes its place |
| Not a terminal (a pipe, a log, `TERM=dumb`) | Plain lines without a bar, padding or carriage returns: the first at once, the next only when both `TransferProgressLine.logInterval` (`30` s) and `TransferProgressLine.logPercentStep` (`10` points) have passed, one at 100% when bytes were transferred, then the same verifying and last lines. The desktop app takes its progress from the last percent (`DesktopBackend.downloadProgress`) |

The rate and the time left are blank for the first
`TransferProgressLine.estimateDelay` (`2` s) and until bytes arrive, and a time
left over `TransferProgressLine.maximumTimeLeft` (`24 * 60 * 60` s) is not
shown. Their columns stay reserved, so the line does not move when they appear.

Each download ends with one last line (`DownloadProgressRenderer`); `<name>` is
the catalog's display name:

| Outcome | Last line |
|---|---|
| Downloaded | `✓ Downloaded <name> (<size> in <time>)`; after a resumed download, `✓ Downloaded <name> (<size> in <time>; <size> of it was already on disk)` |
| Already on disk and verified | `✓ <name> is already downloaded (<size>)` |
| The transfer failed | `Download of <id> stopped at <percent> (<bytes>)`, then the error |
| The files failed their check against the manifest | `Verification of <id> failed: <reason>` |

`darkbloom models download` then prints `Cached at <path>`. The picker prints
nothing more for the model.

Sizes are decimal, as the catalog gives them. The rate leaves out bytes that an
interrupted download already had on disk; the download resumes from them. Code:
`provider-swift/Sources/ProviderCore/Models/ModelDownloadProgress.swift`
(`DownloadProgressRenderer`),
`provider-swift/Sources/ProviderCore/Models/TransferProgressLine.swift`
(`TransferProgressLine`).

If the model's `models--<id>` cache entry is a dangling symlink (for example,
to an unavailable external drive), downloading preserves it as a hidden sibling
`.models--<id>.unavailable-link-<UUID>` and creates a real model directory in the
selected cache. This also applies to downloads from `darkbloom start` and
background prefetch. Reconnect the drive before downloading if you want to keep
using its existing model directory. Valid directory symlinks are followed;
regular files and symlinks to files cause an error and are left intact.
Code: `provider-swift/Sources/ProviderCore/Models/ModelDownloader+Cache.swift`
(`prepareModelCacheDirectory`).

### `darkbloom models remove <id>`

Delete a downloaded model. The command returns a busy error if a download or
revision update currently owns that model's writer lease; retry after it finishes.
`--force` skips confirmation and does not bypass the lease. Code:
`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift` (`remove`),
`provider-swift/Sources/ProviderCore/Models/ModelArtifactWriteLease.swift`
(`acquireIfAvailable`).

```bash
darkbloom models remove <id> [--force]
```

### `darkbloom models location`

Inspect a cache or explicitly save its location in `provider.toml`
(`Models.Location`, `provider-swift/Sources/darkbloom/ModelsLocationCommand.swift`).
No beta flag is involved. Without a saved location, existing providers continue
using the legacy cache even if Hugging Face/XDG variables are exported.

```bash
darkbloom models location                              # terminal menu; status otherwise
darkbloom models location /Volumes/Models/hub           # explicitly save an existing hub root
darkbloom models location --from-env                    # explicitly import and pin the current HF cache
darkbloom models location --check /Volumes/Models/hub   # inspect only; never opts in
darkbloom models location --reset                       # restore the legacy default; retain all weights
```

The menu offers keeping the current location, restoring the default, choosing a
custom path, or importing the detected environment cache. Enter/EOF cancels;
terminal changes require `yes`. An explicit PATH or `--from-env` also works
noninteractively. `--from-env` cannot be combined with PATH, `--check`, or `--reset`.
An import pins the resolved absolute directory; later environment changes cannot
switch it. No valid cache variable means no import and no saved change. See the
[one-time import precedence](../reference/configuration.md#model-cache-location).

Empty writable directories are valid for future downloads. Missing directories
are not created: mount the external volume and create the intended directory
explicitly first. Nothing moves or deletes existing weights, downloads models,
or restarts a running provider. `--reset` returns to the legacy home cache even
when cache environment variables remain set.

Before applying a selection, inspect the chosen directory and confirm the
expected model IDs. `--check` can succeed for an empty writable directory; it is
discovery, not weight-integrity verification or network eligibility. Use
`models list --hash <model-id>` for an on-demand aggregate hash and `doctor` for
serving diagnostics.

After saving, apply the configuration with `darkbloom restart`, or `darkbloom
start` if stopped. Use the intended `--config <path>` on the location command and
`start` for a custom config; restart retains the installed job's config argument.
The CLI reports the selected config, not a running daemon's already-loaded state.

## `darkbloom benchmark`

Run a standardized local inference benchmark.

```bash
darkbloom benchmark [--model <id>] [--prompt <text>] [--iterations <n>] [--max-tokens <n>]
```

| Flag | Description |
|------|-------------|
| `--model <id>` | Model to benchmark (defaults to the largest model that fits) |
| `--prompt <text>` | Prompt text |
| `--iterations <n>` | Number of iterations (default from `ModelBenchmark`) |
| `--max-tokens <n>` | Maximum tokens to generate per iteration |
| `--runtime-generation` | Generate through the production CBv2 slot and emit tokens/text, resolved precision/backend, model/runtime identity, timings and memory as JSON |
| `--runtime-assistant-directory <path>` | Offline local Gemma assistant for `--runtime-generation --runtime-mtp`; normal artifact and target checks apply, with assistant hashes in the report |
| `--runtime-concurrency <sizes>` | Comma-separated batch sizes from 1 to 64 (for example `1,2,4,8`) for `--runtime-generation`; an empty, non-numeric or out-of-range entry refuses the whole list (`RuntimeConcurrencyBenchmark.batchSizes`). One production slot per size, warmed by one identical batch, then distinct greedy rows; a slot whose model policy lowers its width below the size is listed in `refusedCells` instead of measured. JSON carries the verified model hash, prompt hash, render date and per-row prompt-token hashes; per cell, the resolved backend, KV precisions, MTP state and assistant identity; per-row tokens, arrival times of the first, third and first eight tokens, decode rates, chained steps (measured batch) and MTP metrics (warmup included). Exit status 2 when a cell is refused or a row does not end with `length` at its quota or a configured stop token within it (`provider-swift/Sources/ProviderBenchmark/RuntimeConcurrencyBenchmarkReport.swift`, `RuntimeConcurrencyBenchmark.rowFailure`) |
| `--runtime-stagger` | With `--runtime-concurrency`: row i of a B-row batch stops after `max-tokens*(B-i)/B` tokens, so the decode cohort shrinks to one row (speculation resuming as concurrency drops). `--max-tokens` must be at least 3×B for every size, keeping the quotas distinct and at least 3 (`RuntimeConcurrencyBenchmark.rowMaxTokens`); a row that stops before its quota fails the cell |
| `--kv-quantization <precision>` | Live `balanced`, `k8v4`, `k8v8` or `native`; overrides config/environment, otherwise the provider default is native |
| `--kv-checkpoint-quantization <precision>` | Independent complete-checkpoint request with the same values; overrides config/environment, otherwise defaults to balanced; does not enable a cache or change the live backend |

For paired live-cache comparisons, use the same artifact, public prompt and
`--runtime-prompt-date` with `--runtime-generation --kv-backend paged`, once
with `--kv-quantization native` and once with `balanced`. Target-only generation
is the default in this diagnostic; `--runtime-mtp` explicitly includes the
configured artifact assistant. Inline Qwen heads need no separate directory;
Gemma requires `--runtime-assistant-directory` pointing to a local assistant.
The diagnostic never downloads an assistant. A generation limit is reported as `length`,
not a correctness pass. Prefix caches remain off in these runs: emitted
`kvCheckpointQuantization` and a missing `checkpointBackendLayout` do not prove
checkpoint compression. Use the separate
[checkpoint-storage qualification](../developer/test.md#native-inference-checkpoint-storage-qualification)
for encrypted write/restore comparisons.

For native Qwen4 model types, the ordinary command uses the production CBv2
model/factory path with MTP and prefix caching off. It preserves model/tokenizer
EOS, checks complete weight integrity before and after load, and releases the
session between independent runs. Non-native model types keep their generic path
and JSON5 configuration support (`ModelBenchmark.run`,
`provider-swift/Sources/ProviderBenchmark/ModelBenchmarkNativeQwen4.swift`).
Iteration/output counts must be positive. The prefill column measures time to
the first generated token, including prompt preparation; model loading and
integrity hashing are outside the reported iteration time. An eight-token
smoke proves entry-point operation, not sustained decode performance.

For `diffusion_gemma`, the ordinary command uses the
[native block benchmark](../architecture/native-block-inference.md#ordinary-cli-benchmark).
`--kv-backend auto|contiguous|paged` selects live storage. Default native
precision leaves `auto` contiguous on this path. Explicit live `balanced`,
`k8v4` or `k8v8` makes `auto` paged. Explicit `contiguous` requires native live
precision, and an
unavailable paged route refuses quantized construction
(`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+Native.swift`,
`EngineV2SlotFactory.makeProductionBundle`).
The independent checkpoint request retains native encoding for native-block
diffusion; these cache-disabled benchmark runs do not exercise a durable codec.
The prefill column is encoder prefill, not time to first output. Each
`NATIVE_BLOCK_BENCHMARK` JSON row separately reports first committed output,
generation including first-block work, completion usage including EOS, committed
tokens excluding EOS, resolved backend and the production KV grant. Native framing
can be included in committed tokens; the row does not certify a visible-token
performance target. Loading and its integrity hashes have a separate clock.
The numeric `promptTokens` usage count remains separate from the exact
`promptTokenIDs` array (`provider-swift/Sources/ProviderBenchmark/DiffusionGemmaBenchmarkRow.swift`,
`DiffusionGemmaBenchmarkRow`).
The row also exposes existing native execution/prefill quantum counts,
post-first-block commit count and quantum wall-time sum/maximum. Those are work
diagnostics, not output tokens or GPU-only timing. Prefill, refinement and
committed-block re-encoding all contribute native work; do not count the
execution-quanta total as refinement passes without separating those phases.
Emitting these counters adds no sampling or GPU evaluation step.
AR sweep, scheduler-prefill, arrival, teacher-forcing and parity modes reject this
architecture instead of substituting an autoregressive iterator.

Eligible native inference uses the SDK's
[ordered expert-output reduction](../reference/configuration.md#native-diffusiongemma-expert-reduction).
That reference defines `DARKBLOOM_DIFFUSION_EXPERT_UNSORT` and its explicit
rollback. Compare warmed original/optimized runs with unchanged artifact,
prompt, seed and denoising controls; cold JIT timings and isolated kernel
timings do not establish a request-throughput improvement.

For an exclusive native benchmark, the
[descriptor-route diagnostic](../reference/configuration.md#native-diffusiongemma-expert-reduction)
adds `DIFFUSION_PROVIDER_ROUTE` rows. It observes the first iteration and checks
that counters stay disarmed for subsequent iterations; it does not remove the
first sample from the ordinary output. Configure expert routing through
`[gemma_optimizations].weighted_r1`; the benchmark refuses conflicting low-level
environment overrides. DiffusionGemma's separate expert reduction control remains
independent of the Gemma-specific weighted-unsort setting.
The same reference documents opt-in soft-conditioning and native compiled-sampler
candidates. `softEmbeddingCalls` and `compiledSamplerCalls` prove dispatch in the
observed first iteration; subsequent iterations must retain the disarmed counts.
Report first-use compilation separately from warmed results. An environment value alone does not
prove shape eligibility or a request-throughput gain. Keep native weights,
sampling, canvas and output-count oracles identical when comparing either route.

### Teacher-forced scores

`--teacher-forced-input <json>` selects bounded ordinary target scoring with an
explicit model and backend. The UTF-8 JSON input is at most 1 MiB; fields are
defined by `provider-swift/Sources/ProviderBenchmark/TeacherForcedBenchmarkInput.swift`
(`TeacherForcedBenchmarkInput`):

| Field | Required value |
|---|---|
| `modelID` | Exact selected model ID |
| `expectedModelAggregateSHA256` | Verified model aggregate hash, 64 lowercase hexadecimal characters |
| `promptTokens` | Exact nonempty token-ID array, at most 32,768 IDs |
| `continuation` | Exact nonempty token-ID array, at most 256 IDs |

IDs must fit the model's declared vocabulary; the native request bounds and
actual logit geometry are checked by
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2TeacherForcedScores.swift`.
This mode disables prefix caching and MTP, uses a production single-slot KV
grant, and refuses backend fallback. It is mutually exclusive with the other
benchmark modes and rejects `--assistant-model` and `--output`; JSON goes to
stdout (`BenchmarkCommand.swift`, `teacherForcedOptionError`).

The report includes plain top-1 IDs, two diagnostic observations, forward
counts, runtime/input/model hashes and the production grant. `observed` means
finite scores and matching ordinary-forward controls; `inconclusive` preserves
evidence and exits 2. Neither status certifies free generation, model quality
or speculative verification
(`provider-swift/Sources/ProviderBenchmark/TeacherForcedBenchmark.swift`).
See the [developer test procedure](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/test.md#ordinary-teacher-forced-score-diagnostics).

## `darkbloom update`

Check for and apply provider updates.

```bash
darkbloom update [--check-only] [--coordinator <url>] [--timeout <seconds>] [--force]
darkbloom update --rollback [--yes] [--timeout <seconds>] [--force]
```

| Flag | Description |
|------|-------------|
| `--check-only` | Report whether an update is available without installing |
| `--coordinator <url>` | Override coordinator URL |
| `--rollback` | Restore the release kept for rollback and quarantine the installed one ([details](#darkbloom-update)) |
| `--yes`, `-y` | With `--rollback`: do not ask for confirmation |
| `--timeout <seconds>` | Drain deadline: default `600`, valid 0–3600 seconds |
| `--force` | Explicitly permit interruption during activation; default `false` |

The update path verifies bundle, binary, and `mlx.metallib` hashes before
replacing the running binary (`provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`).

On a Mac whose `darkbloom cluster` service runs, the command then asks that
service's supervisor to restart into the installed release together with the
other Mac, after the pair drained, and prints its progress until the restart
(at most `--timeout` seconds); a deferral exits 1. It also ends as soon as this
Mac's cluster service runs the installed release (`This Mac's cluster service now
runs v<version>; the cluster sets itself up again once both Macs run it.`): the
restarted service may report that no update runs before the command reads the
restart
(`provider-swift/Sources/darkbloom/UpdateCommand.swift`, `ClusterServiceUpdateRequest`;
[updating Darkbloom on the pair](two-mac-cluster.md#updating-darkbloom-on-the-pair)).

## `darkbloom autoupdate`

Enable or disable automatic update checks at startup.

```bash
darkbloom autoupdate <enable|disable|status>
```

This toggles `provider.auto_update` in `provider.toml`. It reloads the file
under the same sidecar lock as `darkbloom switch`, preserving a selection saved
by a concurrent switch.

## `darkbloom beta`

Manage configurable beta features. Defaults are feature-specific: the selected
Gemma optimizations default on, while reserved/opt-in features default off.
Provider TOML is authoritative for every serve mode. The Gemma defaults and
missing-key decode are defined in
`provider-swift/Sources/ProviderCore/Config/GemmaOptimizationSettings.swift:16-34`,
with the missing-section fallback in
`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:397-400`.
The shared pre-Metal projection is
`provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift:24-35`.

```bash
darkbloom beta list                 # all features + on/off (default subcommand)
darkbloom beta status [feature]     # details for all features, or one
darkbloom beta enable <feature>     # turn on (then: darkbloom restart)
darkbloom beta disable <feature>    # turn off
```

| Feature | Effect |
|---------|--------|
| `gemma-prefill-layer18` | Default-on layer-18 prefill submission; disable and restart for legacy submission behavior |
| `gemma-weighted-r1` | Default-on atomic weighted-unsort + safe-R1 pair; disable and restart to roll back both |
| `mtp` | MTP policy. Default `auto` requests validated embedded Qwen-family, native Qwen4, Nemotron Lightning and native MiMo heads, and the catalog `spec_dec` assistant for exact `gemma-4-26b-qat-4bit` and the exact Prism/Eigen Bonsai 9B identities under `prism_hadamard_qwen35`. Actual artifact/owner/budget checks remain required; explicit `off` is the rollback |

`enable`/`disable` read-modify-write the TOML config and report whether a restart
is required. Restart is the activation boundary for process-wide optimization
state. The durable locked write and restart instruction are implemented in
`provider-swift/Sources/darkbloom/BetaCommand.swift:201-235`. See
[Beta Features](beta-features.md) for the full guide. `darkbloom beta list` also
accepts `--json`. Under the default `auto` mode a served checkpoint that embeds its MTP head
drafts without any beta toggle. Exact `gemma-4-26b-qat-4bit` also resolves its
external assistant automatically; other checkpoints without an embedded
declaration stay target-only. Missing or invalid assistants fall back to ordinary
decode. Only me (`--local`) also downloads the verified assistant in the background,
using the configured `coordinator.url` catalog, and activates it only when the
current engine is idle. Existing requests keep their engine; insufficient memory
or preparation failure preserves target-only serving. Local parity results are not
a blanket M1-M3/unknown-chip certification.
The published assistant metadata is visible in the
[public production catalog](https://api.darkbloom.dev/v1/models/catalog?type=text)
under `gemma-4-26b-qat-4bit.metadata.spec_dec`.
`kv-quant` was removed in v0.8.0 and is no longer a valid feature id.

## `darkbloom fan` (experimental)

Inspect or opt into provider-only temperature-based fan control.

```bash
darkbloom fan status [--json]
darkbloom fan diagnose [--json]
sudo darkbloom fan enable [--speed 80] [--temperature 45]
sudo darkbloom fan configure [--speed 60...90] [--temperature C]
sudo darkbloom fan disable
sudo darkbloom fan uninstall
```

Ordinary Darkbloom installation leaves the bundled helper dormant. State changes
require explicit `sudo`; read-only status and diagnostics do not. The helper
applies a target only while a signed provider holds an activity lease and a
validated GPU sensor exceeds the threshold. Defaults are 80% of each fan's
reported maximum, engage at 45 C, and release below 40 C. See
[Experimental Fan Control](fan-control.md) for hardware gates and recovery
behavior.

## `darkbloom login`

Link this machine to a Darkbloom account via RFC 8628 device-code flow.

```bash
darkbloom login
```

## `darkbloom logout`

Stop the provider and remove its saved account credential. See the
[logout flags and confirmation rules](#darkbloom-login--darkbloom-logout);
local completion is not confirmation of remote invalidation.

```bash
darkbloom logout
```

## `darkbloom enroll`

Show App Attest setup guidance or check frozen legacy eligibility before MDM
profile setup; see the [enrollment behavior](#darkbloom-enroll--darkbloom-unenroll).

```bash
darkbloom enroll [--coordinator <url>] [--no-open]
```

| Flag | Description |
|------|-------------|
| `--coordinator <url>` | Override coordinator URL |
| `--no-open` | Download the profile but do not open System Settings |

## `darkbloom unenroll`

Without a flag, ask whether to fully exit Darkbloom or remove only MDM and keep serving with App Attest. Enter or closed input cancels without changing anything. The App Attest option requires macOS 27 or later and fresh coordinator removal approval; an unsupported/unqualified choice never falls back to cleanup.

Full exit stops the launchd provider and disables its automatic restart before profile-removal guidance and a separate local cleanup confirmation. If a foreground provider is still running, cleanup is refused. The cleanup removes the current (v2) Secure Enclave signing key; a leftover v1 keychain item is neither read nor removed. Model downloads and server-side account history remain intact.

If profile inventory needs administrator access, run this command in the foreground of an interactive terminal. `sudo` prompts there with terminal echo disabled; only the fixed, read-only profile inventory command is elevated. A denied prompt, noninteractive session, or background terminal job withholds profile-removal guidance. The command does not remove a profile itself; confirm the exact Darkbloom profile in System Settings. See [`attestation.md`](./attestation.md#app-attest-without-darkbloom-mdm).

Code: `provider-swift/Sources/darkbloom/UnenrollCommand+Choice.swift` (`chooseUnenrollmentMode`, `performUnenrollment`); `provider-swift/Sources/darkbloom/UnenrollCommand.swift` (`performFullUnenrollment`). Noninteractive use requires an explicit mode flag.

```bash
darkbloom unenroll [--force] [--no-open]
darkbloom unenroll --keep-serving [--no-open]
```

| Flag | Description |
|------|-------------|
| `--force` | Select full exit and confirm local cleanup; cannot combine with `--keep-serving` |
| `--no-open` | Do not open System Settings |
| `--keep-serving` | Select macOS 27+ App Attest migration directly, retaining account/keys/data |

## `darkbloom local`

Print the local API's address and key: the OpenAI-compatible server of
**Only me** or **Both, me first** on this Mac.

```bash
darkbloom local [--json]
```

`darkbloom local` reads `~/.darkbloom/local.json`, but only advertises it if the
recorded server process is still alive.

## `darkbloom route`

Where your requests go when this Mac's local API can't take them: this Mac
only, your other Macs (free), or your Macs first and then the Darkbloom network
(billed), from `[local] route` and a saved account API key.

```bash
darkbloom route this-mac       # your requests stay on this Mac
darkbloom route my-macs        # then your other Macs (free); needs the account key
darkbloom route my-macs-first  # then your other Macs (free), then the Darkbloom network (billed); needs the key
darkbloom route key            # ask for the key with hidden input, check it, save it in the Keychain
darkbloom route key --stdin    # read it from standard input
darkbloom route key --remove   # remove it: requests stay on this Mac
```

No output line contains the key. Details: [the three routes](#darkbloom-route-this-mac-my-macs-my-macs-first)
and [`darkbloom route key`](#darkbloom-route-key).

## `darkbloom logs`

Show provider logs from macOS unified logging or the legacy log file.

```bash
darkbloom logs [--file] [--follow] [--last <duration>] [--debug] [--lines <n>]
```

| Flag | Description |
|------|-------------|
| `--file` | Read from the legacy log file instead of unified logging |
| `--follow`, `-f` | Stream new lines |
| `--last <duration>` | Historical window, e.g. `1h`, `30m`, `24h` |
| `--debug` | Include debug-level messages |
| `--lines <n>` | Number of lines (only with `--file`) |

### Refusal lines

A request refused as a client error, before its inference task or while its
prompt is prepared, writes one fixed public line: the failure category, then a
reason from the closed `InferenceRefusalReason` set
(`provider-swift/Sources/ProviderCore/Inference/Engine/InferenceRefusalReason.swift`).
A private line pairs the request ID with the same reason; neither contains
request text. The `inference_error` frame sent to the coordinator is the same
as without the line. A prompt-time refusal takes its reason from the typed
error (`InferenceRefusalReason.init(promptRefusal:)`): the `refusal` a prompt
policy attaches to `MultiModelBatchSchedulerEngineError.invalidToolPayload`, or
the error case itself. Other failures, and a client refusal that names no
reason, keep the bare category, such as `Inference failure: invalid request`
(`provider-swift/Sources/ProviderCore/Inference/Engine/InferenceFailure.swift`,
`InferenceFailureLogger`).

| Line | Refused because | Source |
|---|---|---|
| `Inference failure: invalid request (missing sender key)` | The sealed request has no 32-byte sender key | `provider-swift/Sources/ProviderCore/ProviderLoop+InferenceHandler.swift` (`handleInferenceRequest`) |
| `Inference failure: invalid request (undecryptable request)` | The body does not decrypt with this provider's key | same |
| `Inference failure: invalid request (reserved tool schema metadata)` | Tools carry coordinator-only schema metadata without its authenticated protocol, or GLM-5.3-Flash tools carry it at all | same; `GLM5NextPromptPolicy.RawControls` |
| `Inference failure: invalid request (malformed body)` | The body is not a JSON chat request object | `InferenceRefusalReason.init(chatDecodeFailure:)` |
| `Inference failure: invalid request (invalid messages)` | A message does not decode, such as a content part without its URL, or a content part has a type no engine serves (`input_file`, `input_video`, `refusal`, ...) | same; `provider-swift/Sources/ProviderCore/ProviderLoop+InferenceHandler.swift` (`unsupportedContentPartType`) |
| `Inference failure: invalid request (unsupported message role)` | A role other than `system`, `user`, `assistant` or `tool` and their aliases `developer` and `function` | same; `InboundChatNormalization` |
| `Inference failure: invalid request (invalid tool history)` | A history tool call or result does not decode, such as a call without `type` or a non-object legacy `function_call` | same |
| `Inference failure: invalid request (invalid tool arguments)` | A history call's `arguments` is not a string | same |
| `Inference failure: invalid request (invalid tool declaration)` | A declared tool does not decode, such as a function without a name | same; `GLM5NextPromptPolicy.RawControls` |
| `Inference failure: invalid request (invalid tool choice)` | `tool_choice` does not decode, such as a named choice without a name | same |
| `Inference failure: invalid request (unsupported response format)` | `response_format` does not decode, such as `json_schema` without `schema` | same |
| `Inference failure: invalid request (invalid request field)` | Another field has the wrong type, such as a string `temperature` | same |
| `Inference failure: invalid request (unsupported reasoning control)` | A reasoning or template control the model refuses: an unknown effort, a non-positive budget, `preserve_thinking`, an unknown `reasoning` member, `thinking` key or `chat_template_kwargs` key, or a non-Boolean switch; also a `reasoning` field that does not decode, such as a string `reasoning.enabled` | `ProviderPromptContractPipeline.nativeControlsRefusal`; `InferenceRefusalReason.init(chatDecodeFailure:)` |
| `Inference failure: invalid request (contradictory reasoning controls)` | Thinking-off beside a thinking-on switch, effort or budget, or a `reasoning.context` that contradicts `clear_thinking` | `ProviderPromptContractPipeline.nativeControlsRefusal` |
| `Inference failure: invalid request (unsupported tool type)` | A GLM-5.3-Flash tool declaration whose type is not `function` | same |
| `Inference failure: invalid request (invalid tool schema)` | A GLM-5.3-Flash tool schema holding a number it cannot represent exactly, or nested too deeply | same |
| `Inference failure: invalid media (unsupported audio)` | Audio input to a model without native audio | `MediaIngest.rejectUnsupportedAudio` |
| `Inference failure: invalid request (unanswered tool call)` | A GLM-5.3-Flash history call has no result before the next non-tool message or the end of the conversation | `GLM5NextPromptPolicy.validateHistory` |
| `Inference failure: invalid request (unmatched tool result)` | A tool result names no pending call of the turn before it, repeats one, or carries `tool_calls` | same |
| `Inference failure: invalid request (native delimiter in history)` | A history argument name or string value contains GLM tool-call delimiter text | `GLM5NextPromptPolicy.normalizedTextInput` |
| `Inference failure: invalid request (non-text content)` | Image, video or other non-text content on GLM-5.3-Flash's text path | same |
| `Inference failure: invalid request (unsupported forced tool choice)` | A required or named `tool_choice` the model cannot enforce: a schema outside the enforceable subset, or GLM-5.3-Flash image or video input | `ToolChoicePromptPolicy`; `MultiModelBatchSchedulerEngine` |
| `Inference failure: invalid request (request exceeds context)` | The prompt plus `max_tokens` exceeds the model's context window | `EngineV2Bridge` (`advertisedContextExceeded`) |
| `Inference failure: invalid request (unsupported output control)` | An output control the model's engine cannot honor, such as logprobs on an engine without them | `EngineV2Bridge.nativeOutputControlRefusal` |

Prompt-time refusals also use the earlier reasons: a GLM-5.3-Flash history call
with an empty or repeated ID, a bad function name or a non-assistant role is
`invalid tool history`; history `arguments` that are not one exactly
representable JSON object (malformed, duplicate keys, a number that does not
survive the round trip) are `invalid tool arguments`; an invalid or repeated
tool name is `invalid tool declaration`; a required choice without tools or a
named choice of an undeclared function is `invalid tool choice`; a JSON
`response_format` with image or video input is `unsupported response format`;
and render-time control rechecks keep
`unsupported reasoning control` and `contradictory reasoning controls`.

Boot-security diagnostics pass only when SIP and authenticated root are both positively enabled. A missing reading produces a warning, and failed diagnostic commands time out with unknown fields. APNs history is rendered under APNs code-identity readiness on all supported macOS versions, even without an App Attest snapshot. An absent history file is omitted. Zero observed pushes is `[INFO]` with an indeterminate delivery result, not a warning: cached code identity may avoid APNs entirely. Informational results do not fail `--strict`. A recorded App Attest `environment_mismatch` fails the signing diagnostic even when the entitlement is a known production/development value. APNs token presence follows late callbacks; a recorded reply means the local WebSocket write completed, not that the coordinator verified it.

## `darkbloom report`

Collect recent Darkbloom provider unified logs and explicitly upload them to the
coordinator for troubleshooting.

```bash
darkbloom report [--last <duration>] [--dry-run]
```

| Flag | Description |
|------|-------------|
| `--last <duration>` | Time window, e.g. `1h`, `6h`, `24h` |
| `--dry-run` | Print the exact report locally without uploading |

The assembled upload reserves room for App Attest evidence within the coordinator's 10 MiB raw-body limit; older provider-log lines are trimmed as needed. `--dry-run` prints this same bounded payload.

The command runs only when invoked by the provider operator. It collects the
`dev.darkbloom.provider` subsystem, preserves macOS unified-log privacy
redaction, and does not include debug-level messages. Automatic report upload is
disabled.

The device-wide log collector allows 30 seconds, then a 250 ms termination grace before killing an unresponsive child. A timeout returns unavailable evidence without an unbounded wait (`DeviceCheckEvidence.runLog`). Reads retain at most the newest 8 MiB of stdout and 4 KiB of stderr. Parsing skips lines over 64 KiB and retains only the newest 200 matching events in a ring; the output describes the collected log tail rather than claiming complete two-hour coverage.

It also appends App Attest evidence as extra NDJSON lines:

- the daemon's local App Attest snapshot (`source`
  `darkbloom.app_attest_state`), with key history refreshed after each proof,
  ages advanced to report time, process start and the native error chain;
- the APNs push receipt/reply summary;
- device-wide `devicecheckd` / `com.apple.appattest` observations from the last
  2 h (`source` `darkbloom.devicecheck_evidence`). Every outcome carries
  `scope=device_wide` and `attribution=not_attributable_to_darkbloom`: other apps
  can cause these events, so they do not establish this provider's key state.
  Only timestamp, category, message type and closed-pattern numeric matches
  remain, such as `SecKeyCreateSignature failed`, `CryptoTokenKit Code`,
  `AKSError`, `Should fetch CD hash`, `invalidKey` and `unknownSystemFailure`.
  Message text, key identifiers and paths are dropped.

macOS lets only administrator accounts read the system log. From a standard
account, macOS answers `Operation not permitted`. The command reports this and
still uploads the App Attest snapshot. To include the logs, run it from an
administrator account, or run `sudo darkbloom report` if this account is allowed
to use sudo. Under `sudo` it reads the invoking user's daemon state and provider
config (unless `--config` is given), plus that user's `~/.darkbloom/auth_token`
through `AuthTokenStore.loadReadOnly`. It writes no config or token file as
root. An explicit nonempty `DARKBLOOM_AUTH_TOKEN_PATH` replaces that token
path. See `ReportAppAttestEvidence` in
`provider-swift/Sources/darkbloom/Diagnostics/`. `--dry-run` prints every appended
line before anything is uploaded.

## `darkbloom watchdog`

Internal command used by the launchd crash-recovery watchdog. Not intended for
manual use.

## Native pair batch diagnostics

The developer helper `darkbloom-cluster-pair-check run` accepts
`--batch-trace yes|no` (default `no`) and `--batch-logit-directory <absolute-path>`
(default unset). Both require an eligible Qwen plain-pipeline batch with 2...8
lanes and `--evidence none`. The trace writes one content-free geometry summary
on rank 0. The directory belongs to rank 1's Mac, regardless of `--local-rank`;
its parent must exist, and the helper creates a private final directory if needed.
It holds raw native logit rows and private request/frontier metadata at fixed
output ordinals 0, 1, 30, 37, 78 and 88. Capture is bounded and never overwrites.
These diagnostics neither change token selection nor establish normal final-row
qualification or performance. Sources:
`libs/darkbloom-cluster-worker/Sources/PairCheck/PairCheck.swift` (`PairCheck.run`),
`libs/darkbloom-cluster-worker/Sources/DarkbloomClusterQualification/PairConfiguration.swift`
(`validate`, `launchScript`), and [test boundaries](../developer/test.md#two-mac-cluster-checks).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, `--help`, `--version` |
| `1` | `ExitCode.failure` — every runtime error listed above |
| `64` | swift-argument-parser validation error (unknown flag, missing positional, `fan configure` with no option) |
| `130` | `darkbloom sandbox setup` stopped with Ctrl-C while the add-on installer ran |
| `2`, `3`, `4`, other | `darkbloom sandbox setup` exits with a failing add-on installer's own status ([what each means](#installer-progress-events)); `sandbox logs` and `sandbox uninstall` with `tail`'s or the add-on's |
| `3`, `4`, `5`, `6`, `7` | `darkbloom cluster status`: not serving yet, stopped, the other Mac isn't answering, not in a cluster, this Mac's pairing record couldn't be read ([`darkbloom cluster status`](#darkbloom-cluster-status)) |
| `0`, `1`, `3`, `4`, `5`, `64` | `darkbloom start` without a terminal and `darkbloom restart` on a paired Mac: serving; not started (no model chosen, the cluster unreachable, a part still releasing); not serving yet; stopped; the other Mac isn't answering; single-Mac options without `--solo` ([`darkbloom start`](#darkbloom-start)) |
| `75`, `76` | `darkbloom start --cluster-member`: the JACCL guard tore a wedged collective down (`75`); the other Darkbloom app holds this Mac's GPU, or (DevNet) production serves here, so the member's start is refused with that reason on its `Error:` line (`76`, reserved for that alone). The `--always-on` supervisor restarts after `75` without counting a startup failure, and waits for the hold to end after `76` without counting anything ([always-on members](./cluster-always-on.md#what-the-supervisor-does)) |

## Paths and identifiers

| Item | Value | Source |
|---|---|---|
| Install root | `~/.darkbloom/` | `scripts/install.sh` (`INSTALL_DIR`) |
| App bundle | `~/.darkbloom/Darkbloom.app`; swapped atomically, backup in `.install-backup-*` during the swap | `scripts/install.sh` (`commit_staged_app`) |
| CLI symlinks | `~/.darkbloom/bin/darkbloom`, `darkbloom-enclave`, `mlx.metallib` → `../Darkbloom.app/Contents/MacOS/*`; best-effort `/usr/local/bin/darkbloom` | `scripts/install.sh` |
| Capability markers | `Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/{paged-kernel-v1,fan-helper-v1}` | `scripts/install.sh` (`verify_staged_app`, `verify_fan_helper_capability`) |
| Config | `~/.config/darkbloom/provider.toml` (or `--config`); retired legacy locations are not read | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift` (`defaultConfigPath`) |
| Device token | `~/.darkbloom/auth_token` (`DARKBLOOM_AUTH_TOKEN_PATH`) | `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` |
| Local-mode token / discovery | `~/.darkbloom/local_token`, `~/.darkbloom/local.json` (`DARKBLOOM_LOCAL_DIR`), both `0600` | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` |
| Daemon state | `~/.darkbloom/daemon-state.json` (`DARKBLOOM_STATE_FILE`) | `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift` |
| Add-on runtime | `~/.darkbloom/runtime/` (`0700`): `addon.sock` (`0600`, test override `DARKBLOOM_ADDON_SOCKET`), `addon-hold.json` (`0600`, active holds) and the add-on's `ownership.lock` ([IPC reference](../reference/addon-hold-ipc.md#files)) | `provider-swift/Sources/ProviderCore/Addon/AddonHoldPaths.swift` (`AddonHoldPaths`) |
| Darkbloom Sandbox add-on | `~/DarkbloomSandbox/` (test override `DARKBLOOM_SANDBOX_ROOT`), owned by the add-on: the CLI runs its `darkbloom-sandbox` command and reads `agent/agent.log` | `provider-swift/Sources/darkbloom/Sandbox/SandboxAddon.swift` (`SandboxAddon`) |
| PID file | `~/.darkbloom/provider.pid` (`DARKBLOOM_PID_FILE`) | `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` |
| Warm-model journal | `~/.darkbloom/loaded-models.json` (`DARKBLOOM_LOADED_MODELS_FILE`) | `provider-swift/Sources/ProviderCore/Service/LoadedModelsStore.swift` |
| Verified weight hashes | `~/.darkbloom/verified-weights.json` (`DARKBLOOM_VERIFIED_WEIGHTS_FILE`), `0600`; managed GLM load hashes bound to file identities, reused for startup registration | `provider-swift/Sources/ProviderCore/Service/VerifiedWeightHashStore.swift` |
| Watchdog state | `~/.darkbloom/watchdog-state.json` (`DARKBLOOM_WATCHDOG_STATE`) | `provider-swift/Sources/ProviderCore/Service/WatchdogState.swift` |
| KV-backend crash-loop guard | `~/.darkbloom/kv-backend-guard.json` (`DARKBLOOM_KV_BACKEND_GUARD`) | `provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift` |
| App Attest stall restart marker | `app-attest-stall-restart.json` beside the daemon state file, `0600`; time of the last automatic App Attest restart, for a stalled DeviceCheck call or for `is_supported_false` ([limits](../reference/app-attest-shadow.md#bounds-and-credential-lifecycle)) | `provider-swift/Sources/ProviderAppAttest/AppAttestStallRestart.swift` (`AppAttestStallRestartMarker`) |
| App Attest verified marker | `app-attest-verified.json` beside the daemon state file, `0600`; time of the last coordinator App Attest authorization, rewritten at most once per hour. When it is missing at serve start, it is seeded once from the previous daemon state (the last Apple success of an attested key, or an App Attest grant left by an unclean exit), with evidence from the last 7 days. It only allows the `is_supported_false` restart; it never authorizes serving | `provider-swift/Sources/ProviderAppAttest/AppAttestStallRestart.swift` (`AppAttestVerifiedMarker`) |
| Provider run marker | `provider-run.json` beside the daemon state file, `0600`. Set to `running` when a serve process starts and to `clean` (with cause) after its drain or before an update/stall relaunch. Explicit update/stall relaunch causes survive later generic termination callbacks; a failed hand-off restores running state and clears the cause. The next process derives `previous_exit` and `start_reason` from it | `provider-swift/Sources/ProviderCore/Service/ProviderRunMarker.swift`, `ProviderProcessRun.swift` |
| APNs push history | `apns-push-history.json` beside the daemon state file, `0600`. The last 50 code-identity push receipt times and reply times, plus whether a device token was present. No token, nonce or payload | `provider-swift/Sources/ProviderCore/Apns/APNsPushHistory.swift` |
| Provider LaunchAgent | label `io.darkbloom.provider`; `~/Library/LaunchAgents/io.darkbloom.provider.plist`; `RunAtLoad = true`, `KeepAlive = false`; stdout/stderr → `~/.darkbloom/provider.log` | `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift` (`label`, `plistPath`, `logPath`) |
| Watchdog LaunchAgent | label `io.darkbloom.watchdog`; `~/Library/LaunchAgents/io.darkbloom.watchdog.plist`; log `~/.darkbloom/watchdog.log` | `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift` |
| Unified-log subsystem | `dev.darkbloom.provider` | `provider-swift/Sources/darkbloom/LogsCommand.swift` (`Logs.subsystem`) |
| Model cache | Hugging Face hub layout under the [resolved model cache](../reference/configuration.md#model-cache-location) | `provider-swift/Sources/ProviderCoreFoundation/ModelScanner+CacheDirectory.swift` (`ModelScanner.resolveCache`) |
| Keychain KEK item | service `io.darkbloom.kv.kek.v1`; access group `SLDQ2GJ6TL.io.darkbloom.provider` (`DARKBLOOM_KEYCHAIN_ACCESS_GROUP`) | `provider-swift/Sources/ProviderCore/KVCache/WrappedKEKStorage.swift` (`defaultService`); `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` (`defaultAccessGroup`) |
| Secure Enclave key label | `io.darkbloom.provider.attestation-signing.v2`; a leftover retired `…v1` item is never read | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` (`defaultLabel`) |
| Apple Team ID | `SLDQ2GJ6TL` (pinned in installer requirements and fan IPC) | `scripts/install.sh`; `provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift` (`teamID`) |
| Fan helper files | `/Library/PrivilegedHelperTools/io.darkbloom.fan-helper`, `/Library/LaunchDaemons/io.darkbloom.fan.plist`, `/Library/Application Support/Darkbloom/fan-policy.json`, `…/fan-session.json` | `provider-swift/Sources/DarkbloomFanService/FanServiceConfiguration.swift` |

### `provider.toml` keys read by the CLI

Defaults are the `ProviderConfig` initialisers
(`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`); a missing
key decodes to its default, and that file is the complete schema (this table
lists the keys an operator is likely to set). Environment variables, which
override `provider.toml` for one process, are in
[`reference/configuration.md`](../reference/configuration.md#provider-cli-darkbloom).

| Key | Default | Effect |
|---|---|---|
| `[provider] memory_reserve_gb | 4 | GiB withheld from the selected OS-available/MLX load budget; the larger unified-cap reserve still applies. By default OS availability includes inactive pages or, when larger, the reclaimable file page cache, so this is not a free-page floor. Set process-start DARKBLOOM_MEMORY_AVAILABILITY=free-only for shared hosts; see [memory admission](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/scheduling.md#shared-host-memory-admission). |
| `[provider] auto_update` | `true` | Startup + periodic self-update; on a `darkbloom cluster` Mac, the pair's coordinated update at its update slot ([cluster service](cluster-always-on.md#the-pairs-coordinated-update)) |
| `[provider] auto_restart` | `true` | Arm the watchdog LaunchAgent |
| `[provider] update_jitter_seconds` | `300` | Max random delay before an automatic install or a network provider drains a model for a prepared MTP replacement; serving continues during the delay. `0` disables jitter; capped at `3600`. Only me's (`--local`) MTP upgrades skip this delay. Random staggering provides no fleet availability guarantee (`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`, `updateJitterSeconds`; `provider-swift/Sources/ProviderCore/Update/UpdateJitter.swift`, `delay`; `provider-swift/Sources/ProviderCore/ProviderLoop+MTPDrain.swift`, `waitBeforeMTPUpgradeDrain`) |
| `[backend] enabled_models` | `[]` | Advertise only these ids; empty = all serveable. When set, it also bounds coordinator model commands and rollouts ([operator filter](../reference/configuration.md#provider-model-selection)) |
| `[backend] model_cache_directory` | unset | Explicit saved hub directory; set or import once with `models location`, clear with `--reset`. Ambient cache variables never override it; hand-written relative paths are anchored to the config file (`provider-swift/Sources/ProviderCore/Config/ModelCacheConfiguration.swift`, `ConfigManager.modelCacheDirectory`) |
| `[backend] idle_timeout_mins` | `60` | Unload a model idle this long; `0` disables; paused during active or explicitly paused Autopilot |
| `[backend] max_model_slots` | `3` | Resident models |
| `[backend] engine_v2_max_concurrent` | Absent: automatic, legacy `4` (`8` on M5 Pro, Max and Ultra for models on the native `auto` paged allowlist); explicit values preserved | Concurrent requests per engine, bounded by exact reviewed profile or legacy `[1, 8]`, architecture and memory. Only an automatic setting may inherit a reviewed or M5 paged higher default; a width above the configured one returns to it under Low Power Mode or thermal pressure. `ServingPerformanceProfiles`, `BackendSettings` |
| `[backend] engine_v2_max_concurrent_by_model` | `{}` | Exact model ID → operator cap; overrides the default for that model under the same qualification, architecture and memory bounds. `status` and `doctor` show the default policy and all configured model overrides, with unknown-profile bounds when different from the requested cap (`provider-swift/Sources/ProviderCore/Inference/Performance/ServingPerformanceProfile.swift`, `ServingPerformanceProfiles.summary`) |
| `[backend] engine_v2_kv_backend` | `"auto"` | `auto` / `paged` / `contiguous`; per-model table `engine_v2_kv_backend_by_model` takes precedence. Only live packed precision requires paged. Native auto follows the [exact qualified-artifact allowlist](../architecture/prefix-cache.md#kv-layouts) and retains observable contiguous fallback; checkpoint compression does not change it (`EngineV2KVBackendPolicy.parseSelection`, `preferredBackend`) |
| `[backend] engine_v2_kv_quantization` | `"native"` | Live attention precision: `balanced` K4/V4, `k8v4` K8/V4, `k8v8` K8/V8 or `native`. Explicit live packed `auto` selects paged; unavailable paging refuses rather than silently serving native. Its durable reuse remains the existing complete packed contract; legacy resident/tensor prefixes stay disabled. MiMo remains native (`EngineV2KVQuantizationPolicy.resolve`). |
| `[backend] engine_v2_kv_quantization_by_model` | `{}` | Exact model-ID live precision overrides the global setting; `DARKBLOOM_CBV2_KV_QUANTIZATION` overrides both. Existing explicit live `balanced` settings remain live packed. MiMo exclusion precedes parsing. |
| `[backend] engine_v2_kv_checkpoint_quantization` | `"balanced"` | Independent complete-checkpoint encoding request with the same four values. Eligible native paged and contiguous targets encode older attention rows and restore to native state. Unsupported layouts retain native encoding; live-packed targets keep their existing packed format. This does not enable caching, force paging or reduce native memory admission. See [numerical limits and fallback](../architecture/kv-cache-quantization.md#native-execution-with-quantized-checkpoints). On a two-Mac cluster it also sets the pair's SSD prompt-prefix record precision for the pair's public model; both Macs must resolve the same value ([cluster record precision](../reference/configuration.md#cluster-ssd-prefix-record-precision)). |
| `[backend] engine_v2_kv_checkpoint_quantization_by_model` | `{}` | Exact model-ID checkpoint request overrides the global setting; `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION` overrides both. MiMo remains native before parsing. |
| `[backend] mtp_mode` | `auto` | Written by `darkbloom beta enable|disable mtp` |
| `[backend] mtp_acceptance` | unset (resolves to `typical`, delta `0.2`) | `exact` / `typical` draft acceptance for eligible sampled target-prefix requests. `typical` keeps a draft when the target's filtered probability for it is above `min(1, 0.2 * exp(-H))` (`H` = the target row's entropy in nats); sampled output is approximate, not distribution-exact. Greedy requests never change. Native MiMo remains exact and does not apply this preference. This setting does not enable disabled MTP or widen eligibility. Parsing ignores case and surrounding whitespace; unknown values warn and resolve to `exact` (`provider-swift/Sources/ProviderCore/Inference/MTP/MTPAcceptancePolicy.swift`, `resolve`) |
| `[backend] mtp_acceptance_by_model` | `{}` | Exact model ID to acceptance string; overrides `mtp_acceptance` for that model. An unknown override resolves to `exact`, not the global value. Same eligibility and native MiMo exclusion as above (`MTPAcceptancePolicy.resolve`) |
| `[backend.model_autopilot] enabled` | `false` | Experimental cached-inventory enrollment/consent, not activation; nonempty verified inventory is required, and only a live lease enables residency control (`provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotSettings.swift`) |
| `[backend.model_autopilot] min_dwell_seconds` | `1800` | Minimum residence before Autopilot replacement; runtime clamps to `60...86400` (`ModelAutopilotSettings.effectiveMinDwellSeconds`) |
| `[backend.model_autopilot] pinned_models` | `[]` | Models autopilot must retain; configured `[backend] model` is additionally pinned (`provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+Autopilot.swift`, `autopilotPinnedModels`) |
| `[backend] startup_preload` | `true` | Preload `preload_models` when set, otherwise selected models (previously loaded first on coordinator starts), within slot and memory limits |
| `[coordinator] url` | Build default: `"wss://api.darkbloom.dev/ws/provider"` for prod builds, `"wss://api.dev.darkbloom.dev/ws/provider"` for dev release builds (`provider-swift/Sources/ProviderBuildEnvironment/BuildEnvironment.swift`) | The installer binds it to the coordinator that served it: another coordinator, such as dev, writes its URL; the production installer removes the line so this default applies (`scripts/install.sh`, `bind_provider_coordinator`) |
| `[coordinator] heartbeat_interval_secs` | `5` | Heartbeat; state file refresh is half of it |
| `[coordinator] private_only` | `false` | Serve only the owner's [self-route](./self-route.md) traffic |
| `[gemma_optimizations] prefill_layer18`, `weighted_r1` | `true` | See [beta features](./beta-features.md) |
| `config_version` | retired | Ignored top-level key left by releases up to v0.9.9; no longer written |
| `[backend] continuous_batching`, `adaptive_prefill`, `engine_v2`, `legacy_compiled_decode`, `kv_quant`, `mtp` | retired | Parsed for presence only; one startup WARN each (`RetiredCodingKeys`). The boolean `mtp` is superseded by `mtp_mode` |

Both precision parsers ignore case and surrounding whitespace. `k4v4`, `int4`
and `on` mean `balanced`; `int8` means `k8v8`; `off` and `0` mean `native`.
An empty value selects that control's default. Invalid selected values fail
parsing except on the early-excluded MiMo path. Native live execution does not
make a lossy checkpoint exact; choose native checkpoint storage as well when
an exact-native replay control is required.

To restore exact acceptance, set `mtp_acceptance = "exact"` under `[backend]`
in `provider.toml` and restart the provider. Per-model entries take precedence:
remove any `"typical"` overrides from `[backend.mtp_acceptance_by_model]`, or
set them to `"exact"` too. To opt out for only one model, set its exact model
ID to `"exact"` in that table. Removing both settings restores the typical
default, not exact acceptance. The benchmark default `--mtp-acceptance exact`
is unchanged; see the [benchmark-only environment rule](../reference/configuration.md#engine-and-scheduler).

For foreground/local mixed-prefill tuning, `DARKBLOOM_CBV2_MIXED_PREFILL_CAP`
sets a process-wide token cap and `DARKBLOOM_CBV2_MIXED_PREFILL_CAP_BY_MODEL`
accepts comma-separated exact overrides such as `gemma-4-26b-qat-4bit=128,gpt-oss-20b=256`.
Per-model values precede the global value, then a reviewed performance profile.
Positive Gemma caps retain the 128-token floor; `0` defers prefill while decoding.
Pure-prefill stripes are unchanged. These variables are not forwarded to a LaunchAgent;
see the [scheduler environment reference](../reference/configuration.md#engine-and-scheduler).

## LaunchAgent environment passthrough

For sandboxed foreground/local startup, `TMPDIR` selects the anonymous runtime
metallib snapshot directory. It is not forwarded to the background provider;
see [runtime metallib snapshots](../reference/configuration.md#runtime-metallib-snapshots)
for accepted paths, failure behavior, and serving-process scope.

The [MiMo candidate controls](../reference/configuration.md#native-mimo-v26-candidate)
are process-scoped settings, not new CLI subcommands or release switches. Native
attention and admitted grouping default on; other experimental kernels remain
opt-in. The native factory requests larger eligible solo-text chunks without
changing explicit stripe overrides or memory safeguards. Only the
standing-residency and complete-prefix controls are included in
`LaunchAgent.inferencePassthroughEnvKeys`; other MiMo overrides require
foreground/local serving. The native benchmark uses the managed
load/retirement route. Exact native MiMo ordinary dispatch is implemented;
benchmark success alone does not qualify API or catalog availability. `mtp_mode = "auto"` requests genuine inspected MiMo embedded heads by default;
`mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` disables speculation. Actual native
assembly and proposal/acceptance metrics—not the setting—prove activation.
Serial-target verification remains default; the rectangular flag does not
itself enable MTP. No documented flag enables missing paging,
media-prefix or coordinator audio capabilities.

Model-cache locations are read from `provider.toml`; Hugging Face/XDG cache
variables are neither forwarded nor runtime overrides. The optional
[`--from-env` import](#darkbloom-models-location) saves an absolute path once,
so the foreground CLI and daemon use the same explicitly selected directory.

The [Bonsai performance profile](../reference/configuration.md#bonsai-performance-qualification)
uses source-default-on eligible paths in foreground and daemon processes. It
leaves model bytes, native precision, context limits and MTP capabilities unchanged.
Explicit `0` restores the prior path; other explicit values except `1` also
disable it. These names are not daemon shell-environment passthrough entries:
foreground overrides work, but do not assume a shell setting reaches an installed
LaunchAgent. The generic constant-cache kill switch remains effective.

For native Flash-Next foreground/local serving, the lower-only
`DARKBLOOM_QWEN4_LISTING_CONTEXT` control bounds the complete request envelope.
Its parsing, default and mandatory PLE acceptance setting are in the
[candidate configuration reference](../reference/configuration.md#native-flash-next-candidate).
The same reference describes the default Qwen4 full-KV/PV32/layer-submission
profile and its explicit `0` rollback controls. It primarily affects decode and
short MTP verification, not larger prefill chunks. These Qwen-specific controls
are not in the daemon passthrough list below: source defaults apply there,
while shell overrides require foreground/local serving. This candidate adds
no release or catalog command.

`darkbloom start` copies only these variables from the invoking shell into the
provider plist's `EnvironmentVariables`
(`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`,
`passthroughEnvKeys` + `inferencePassthroughEnvKeys`,
`passthroughEnvironment`). Every other variable — including `PATH` and all the
media, remaining SSD-prefix and memory-cap tunables — reaches the engine only under
`darkbloom start --foreground` or `--local`. The `DARKBLOOM_PREFIX_CACHE` switch
defaults to enabled for the exact Qwen, Nemotron Lightning and Bonsai 2 artifacts,
Gemma 4 26B QAT (`gemma-4-26b-qat-4bit`), GPT-OSS 20B (`gpt-oss-20b`) and the
exact native MiMo identities; see
[prefix-cache defaults](../architecture/prefix-cache.md#kv-layouts). Other models need an
explicit affirmative value for SSD caching. Resident payload retention requires
`DARKBLOOM_PREFIX_CACHE_MEMORY=1`; both switches are forwarded to the daemon,
and the global disable wins (`PrefixCachePolicy.isEnabled`, `isMemoryEnabled`). Coordinator cache preference separately requires
`EIGENINFERENCE_CACHE_ROUTING_MODE=on`; its default is `off`, and no provider CLI
cache setting enables it ([coordinator/registry/config.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/registry/config.go), `ReadConfig`). Resident
routing also requires the separate live capability described in
[cache-aware-routing.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/cache-aware-routing.md). Effects and defaults are specified
once in [`reference/configuration.md`](../reference/configuration.md).

`DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` overrides the compiled SSD
write budget when `[cache].daily_write_gb` is absent. A saved daily choice wins
over the environment, so `darkbloom cache set` also works with an older plist.
It and `DARKBLOOM_PREFIX_CACHE_DISK_GB` are also forwarded when
`darkbloom start` installs the launchd job. An ordinary `darkbloom restart` reuses
the saved plist and does not import newly exported shell variables; stop and
start with the intended environment to update them. See the
[SSD cache limits](../reference/ssd-kv-cache.md#size-and-eviction-rules).

`DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE` and `DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES`
control the explicitly opted-in recurrent checkpoint bank in foreground/local processes; they are
not forwarded into the LaunchAgent. Their defaults and budget semantics are
listed in the
[`resident cache configuration`](../reference/configuration.md#resident-recurrent-prefix-cache)
table (`provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Hybrid.swift`,
`hybridConfig`). They do not change `mtp_mode`; eligible persistent assistants
must support the checkpoint contract described in
[`prefix caching`](../architecture/prefix-cache.md#resident-tiers).

| Variable | Read by |
|---|---|
| `DARKBLOOM_PREFIX_CACHE_MEMORY` | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`memoryEnvironmentFlag`) |
| `DARKBLOOM_PREFIX_CACHE` | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`environmentFlag`) |
| `DARKBLOOM_MIMO_COMPLETE_PREFIX` | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`isMiMoCompletePrefixEnabled`); unset/empty uses the model default; `0` disables native MiMo text-prefix caching |
| `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` (`incrementalCheckpoints`); a negative value writes complete checkpoints instead of deltas |
| `DARKBLOOM_MIMO_PERSISTENT_WIRED_RESIDENCY` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/MiMo/MiMoV26WiredResidency.swift` (`isEnabled`) |
| `DARKBLOOM_GLM_PERSISTENT_WIRED_RESIDENCY` | `provider-swift/Sources/ProviderCore/Inference/Models/GLM5Next/GLM5NextWiredResidency.swift` (`isEnabled`); on by default, `0`/`false`/`no`/`off` rolls back to per-command-buffer residency |
| `DARKBLOOM_MLX_RESOURCE_DEBUG` | forwarded to `mlx-swift-lm` |
| `DARKBLOOM_TTFT_GDN_BLOCKED` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/GatedDelta.swift` (`GatedDeltaPrefill.mode`); `0` keeps the stock Qwen GDN prompt kernel |
| `DARKBLOOM_TTFT_SHAPE_WARMUP` | `provider-swift/Sources/ProviderCore/Inference/Performance/ModelCalibrationPolicy.swift` (`shapeWarmupEnvironmentKey`); `0` disables the load-time shape warmup, `always` skips its shader-cache probe |
| `DARKBLOOM_CBV2_PAGED_KV` | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVBackendPolicy.swift` |
| `DARKBLOOM_CBV2_KV_QUANTIZATION` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVQuantizationPolicy.swift` (`resolve`, live), as `EngineV2KVQuantizationPolicy`; cluster pairs: `DistributedInstalledKVQuantization` |
| `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVQuantizationPolicy.swift` (`resolve`, checkpoint), as `EngineV2KVQuantizationPolicy` |
| `DARKBLOOM_CBV2_MTP` | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift` |
| `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS` | MTP verification policy (tighten-only cap) |
| `DARKBLOOM_KV_BACKEND_GUARD` | `provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift` |
| `DARKBLOOM_MLX_CACHE_LIMIT_GB` | `provider-swift/Sources/ProviderCore/Inference/Memory/MLXMemoryGuard.swift` (`defaultCacheLimitGB`) |
| `DARKBLOOM_MLX_MEMORY_RESERVE_GB` | `provider-swift/Sources/ProviderCore/Inference/Memory/MLXMemoryGuard.swift` |
| `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` (`maxPartialPrefillsKey`) |
| `DARKBLOOM_CBV2_PREFILL_CHUNK`, `DARKBLOOM_CBV2_STEP_TOKENS` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` (`prefillChunkKey`, `stepTokenBudgetKey`) |
| `DARKBLOOM_PREFILL_DEADLINE_MODE` | `provider-swift/Sources/ProviderCore/Inference/Engine/PrefillDeadlineMode.swift` (`environmentKey`) |
| `DARKBLOOM_TTFT_ADMISSION_FIXES` | `provider-swift/Sources/ProviderCore/Inference/Performance/Deadline/AdmissionRateEstimators.swift` (`DeadlineAdmissionFixes.environmentKey`) |
| `DARKBLOOM_TTFT_IDLE_CACHE_SWEEP` | `provider-swift/Sources/ProviderCore/Inference/Memory/GlobalKVCacheBudget.swift` (`idleCacheSweepEnvironmentKey`) |
| `DARKBLOOM_TTFT_SEGMENT_RETENTION` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+SegmentedBackend.swift` (`segmentRetentionEnvironmentKey`) |
| `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS` | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+SegmentedBackend.swift` (`segmentHostZerosEnvironmentKey`) |
| `MLX_GATHER_QMM_EXPERT_SLICES` | only when the shell value is exactly `1` (`GemmaOptimizationEnvironment.daemonDrainPassthrough`, `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift`) |
| `DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION` | only when the shell value is exactly `1`; selects the [opt-in worker candidate](../reference/configuration.md#app-attest-worker-qualification) (`AppAttestWorkerSelection`, `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`) |

To opt a background provider into the worker candidate, stop it and run
`DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION=1 darkbloom start`. Restart and watchdog
recovery reuse that saved choice; stop/start without the flag restores the default.
Native diagnostic/fault-injection flags are never forwarded to the daemon.

The watchdog plist carries its own list: `DARKBLOOM_NO_UPDATE_CHECK`,
`DARKBLOOM_STATE_FILE`, `DARKBLOOM_WATCHDOG_STATE`, `DARKBLOOM_KV_BACKEND_GUARD`
(`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`).
`DARKBLOOM_NO_UPDATE_CHECK` is **not** forwarded to the provider daemon; disable
automatic updates with `darkbloom autoupdate disable`.

## Runtime constants

| Constant | Value | Source |
|---|---|---|
| Coordinator reconnect backoff | `ExponentialBackoff(base: 1.0, max: 30.0)` s | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorReconnectPolicy.swift` (`CoordinatorReconnectPolicy`) |
| Backoff reset after a stable session | `stableSessionDuration = .seconds(60)`, counted from the `register` frame | same |
| Reconnect wait after close code `1012` (service restart) | `serviceRestartDelayRange = 0...1` s, drawn at random; the backoff does not grow | same |
| WebSocket ping interval / pong timeout | `pingInterval = 10.0` s / `pongTimeout = 30.0` s | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Connection.swift` |
| Coordinator handshake deadline (TCP, TLS and WebSocket upgrade to `.ready`) | `defaultTimeout = 30` s; a stalled handshake is cancelled and retried with the reconnect backoff | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorConnectionHandshake.swift` (`CoordinatorConnectionHandshake`) |
| State-file and capacity refresh | every `max(1, heartbeat_interval_secs / 2)` s; the heartbeat default is in the [`provider.toml` table](#providertoml-keys-read-by-the-cli) | `provider-swift/Sources/ProviderCore/ProviderLoop+Capacity.swift` |
| State-file stale threshold | `isStale(maxAge: 90)` s; `doctor` calls the daemon wedged after `max(8 × refresh period, 90)` s | `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift`; `provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift` (`wedgedAfterSeconds`) |
| Idle unload | `idle_timeout_mins` ([`provider.toml` table](#providertoml-keys-read-by-the-cli)); polled every 60 s; unloads the model, the daemon keeps running | `provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift` |
| Watchdog check interval | `checkIntervalSeconds = 60` | `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift` |
| Crash-loop guard trip | `crashLoopTripThreshold = 3` restarts | `provider-swift/Sources/ProviderCore/Service/WatchdogDecision.swift` |
| Auto-update first check / interval / drain | `300` s / `1800` s / `120` s | `provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift` (`autoUpdateInitialDelay`, `autoUpdateInterval`, `updateDrainTimeout`) |
| Update quarantine | `rollbackThreshold = 3`; `defaultStabilizationSeconds = 600` | `provider-swift/Sources/ProviderCore/Update/UpdateRecoveryState.swift` |
| Release endpoint | `GET /v1/releases/latest?platform=macos-arm64` | `provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift` |
| Update banner timeout | 2 s | `provider-swift/Sources/ProviderCore/Update/UpdateBanner.swift` |
| Local chat body cap | `localInferenceMaxUploadBytes = 32 * 1024 * 1024` | `provider-swift/Sources/ProviderCore/Server/LocalChatUploadResponder.swift` |
| Local bind wait | 5 s | `provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift` (`waitUntilBound`) |
| Fan lease / renewal | `leaseDurationSeconds = 15` / `renewalIntervalSeconds = 5` | `provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift` |
| Fan policy defaults | trigger `45` °C, release `40` °C, speed `80` %, engage after `3` samples, release after `30`; speed range `60`–`90` | `provider-swift/Sources/DarkbloomFanCore/FanPolicy.swift` |
| Minimum RAM to serve | `hardware.memoryGb` floor — [`../architecture/hardware-support.md#context`](../architecture/hardware-support.md#context) | `provider-swift/Sources/darkbloom/Start/StartCommand+Preflight.swift` |

## Related

- [Installation](./installation.md) · [Quickstart](./quickstart.md) · [Troubleshooting](./troubleshooting.md)
- [Use your Mac yourself, first](./local-first.md) · [The local API](./direct-mode.md) · [Self-route](./self-route.md) · [Fan control](./fan-control.md) · [Beta features](./beta-features.md) · [Darkbloom Sandbox](./sandboxes.md)
- [`reference/configuration.md`](../reference/configuration.md) — every environment variable and config key.
- [Attestation](./attestation.md) — trust levels; [`architecture/security/attestation.md`](../architecture/security/attestation.md) for the mechanism.


GPT-OSS benchmark and foreground execution supports the [performance controls](../reference/configuration.md#gpt-oss-performance-controls). The full-projection and kernel rollback modes support paired comparisons with identical request inputs.

### Autopilot enrollment fields

Source: `provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotSettings.swift` (`ModelAutopilotSettings`).

| `[backend.model_autopilot]` key | Default | Meaning |
|---|---|---|
| `consent_recorded` | `false` | An explicit startup decision was saved |
| `selected_models` | `[]` | The saved selection: exact approved cached network build IDs; explicit inventory refresh updates it, ordinary restarts do not; empty cannot enroll. With saved consent the running provider adds every verified downloaded catalog build to the Autopilot set it reports ([Autopilot set](../architecture/model-autopilot.md#the-autopilot-model-set)) |
| `revision` | empty string | CLI-generated identity for the approved configuration |
| `paused` | `false` | Suspend new automatic changes while retaining ready models |
| `min_idle_seconds` | `60` | Inactivity guard, independent from minimum residence |

## GLM automatic finite-calibration placement

`darkbloom cluster glm-calibration-candidates --input /absolute/quote-template.json --planner-sha256 <installed-helper-sha256> [--speed /absolute/measurement.json ...]` scans every structural GLM boundary on this Mac using the installed plan helper. The owner-only template may omit `request.selection.cut`. The scan performs metadata reads and device queries, acquires local metadata exclusion, and loads no model. Its result is an observation, not an authorization.

Collect a snapshot on each Mac, retain both as owner-only files, then pass the same two snapshots on both Macs:

```sh
darkbloom cluster glm-calibration-run --input /absolute/dispatch.json \
  --placement /absolute/rank0.candidates.json \
  --placement /absolute/rank1.candidates.json
```

The command chooses a cut automatically, inserts it into the local quotation in memory, and follows the existing signed quote, pair agreement, owner, live admission and finite-run path. Snapshots expire after 120 seconds; a changed local template or lack of a common feasible cut refuses before launch. The quotation worker rechecks current memory, so a changed device can refuse a previously feasible choice. Resample both Macs instead of increasing bounds or forcing a cut. Omitting `--placement` retains explicit-cut diagnostic behavior. The JSON result includes `automaticPlacement` with the selected cut, prediction provenance and separate measured-best/calibrated flags.

The finite experiment accepts the following scope; these are calibration
ceilings, separate from general serving limits:

| Field | Bound | Validation source |
|---|---|---|
| Prompt / prefill chunk | `1...2048` each; chunk no greater than the actual prompt | `GLM5NextCalibration.Authorization.validate`, `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/GLM5Next/Qualification/GLM5NextCalibration.swift` |
| Output | `1...16` | Same authorization and the selection validators |
| Selected context | At least selected maximum prompt + maximum output, at most `2064` | `GLM5NextCalibrationDocument.validate`, `provider-swift/Sources/ProviderCore/Inference/Distributed/Calibration/GLM5NextCalibrationDocument.swift`; `GLM5NextAutomaticPlacement.scan`, `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/GLM5Next/Metadata/GLM5NextAutomaticPlacement.swift` |

A full 2048-prompt/16-output experiment requires context 2064. Obtain fresh
matching quotes and scope bindings from the source-matched installed helpers;
older lower-scope quotes cannot authorize the larger request. Experimental
workspace allowances do not become measured serving evidence. The
[GLM cluster prefill contract](../architecture/inference.md#glm-cluster-prefill-bounds)
retains separate logical-array, raw-frame and encrypted-record bounds.

These commands do not enable a public GLM endpoint. See [placement semantics](../architecture/inference.md#exact-quote-placement).

The `cluster` setup installs its background service with the enclosing app's
Local Network identity. A signed app keeps serving after the setup terminal
closes. A development fallback names its session lifetime limitation on screen;
keep that Terminal or SSH session open. See [cluster service
permissions](cluster-always-on.md#permissions-asked-once). When macOS keeps a
Mac's link follower off the local network, its log says `this process may not
reach the local network: macOS refused the dial before the cable was tried…`,
and the leading Mac's ✗ gives that as the other Mac's reason instead of asking
whether it is on.

## GPT-OSS native pair batch qualification

For the registered GPT-OSS text row, `darkbloom-cluster-pair-check --batch-lanes N`
accepts 2...8 in plain pipeline with `--evidence none`. Use the existing
`--batch-request`, `--batch-wave`, `--batch-solo` and `--batch-cancel-after`
options to compare requests alone and together and exercise lane retirement.
Qwen's `--batch-trace` and `--batch-logit-directory` diagnostics remain refused
for GPT-OSS. The default is one lane; an accepted configuration is not measured
correctness or throughput evidence. See [owner checks](../developer/test.md#gpt-oss-batch-owner-checks)
and [configuration](../reference/configuration.md#gpt-oss-cluster-batch-lanes).
Sources: `libs/darkbloom-cluster-worker/Sources/DarkbloomClusterQualification/PairConfiguration.swift`
and `PairBatchCancellation.swift`.

### Automatic cluster batch selection

A managed `start --local --distributed` API can widen supported text pipeline
execution from queued demand without a batch environment setting. Explicit
`DARKBLOOM_CLUSTER_BATCH_LANES`, `DARKBLOOM_CLUSTER_FORCE_MODE` or
`DARKBLOOM_CLUSTER_HANDOFF_MODES` retains the selected diagnostic behavior.
See [automatic local cluster batching](../architecture/inference.md#automatic-local-cluster-batching)
for memory bounds, lifecycle and exclusions. Source:
`provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/DistributedAutomaticBatchFactory.swift`.

### Installed tensor-parallel synchronization diagnostic

A local `MLX_METAL_FAST_SYNCH=0` or `1` in each Mac's cluster service
process reaches its fixed owner child and native TP worker as a typed boolean.
Only those exact values are forwarded; absence keeps the worker's normal default.
This is a diagnostic, not a placement or batch-width setting. Installed service
jobs do not inherit a later terminal's environment: supply the setting in each
service job and restart the service before the comparison. Verify fresh native
`darkbloom-collective-sync-v1` startup lines on both Macs, then restore the jobs
and restart after the diagnostic. See the [configuration contract](../reference/configuration.md#installed-tensor-parallel-synchronization).

The optional local `MLX_EAGER_FENCE_COMMIT=0|1` diagnostic uses the same restart
and restoration procedure. It leaves the default off and requires a fresh
`darkbloom-eager-fence-commit-v1 enabled=0|1 source=launcher` marker from each
native TP worker. A service-job setting alone does not prove forwarding. Keep
batch width and other guards fixed when comparing synchronization behavior.

### Qwen27 tensor batch planning metadata

The private `darkbloom-cluster-plan tensor-batch-scope --model-dir DIR
--prompt-tokens N --output-tokens N --batch-lanes N --chunk-size N` helper emits
the full native batch LOAD quotation of every registered Qwen TP row (9B, 27B,
Qwen3.5/3.6 35B A3B); it never loads model tensors
or selects a deployment. Automatic placement uses it before draining and
again after old-owner release. The normal measured mode comparison remains
authoritative. The [configuration reference](../reference/configuration.md#native-automatic-batch-quote)
defines the response and supported saved widths. Source:
`libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Placement/ClusterPlacementTool.swift`.

### Qwen27 TP assistant setup and native diagnostics

Run `darkbloom cluster local` for the catalog Qwen3.8 27B model to serve it with its embedded assistant. The assistant is discovered and fully priced under the existing `backend.mtp_mode` setting; no internal verification or inventory option is required in the normal flow. Verify the saved policy against both workers' actual READY before serving. Plain `darkbloom cluster` serves through Darkbloom, and under the default `auto` it plans the model without the assistant, because a setup registered with the coordinator carries none (the assistant is not qualified for public traffic). Explicit `on` keeps the assistant there too, and the pair is then not offered to the coordinator. Explicit `off` retains the ordinary target with its complete width-one quote. See [configuration](../reference/configuration.md#qwen27-tp-assistant-policy), [the speed tradeoff](two-mac-cluster.md#the-steps-once) and [native ownership](../architecture/inference.md#qwen27-tensor-parallel-resident-assistant).

The internal worker still accepts diagnostic `--mtp-depth N` in 1...4 for keyed 9B or 27B Qwen TP with paged KV (the A3B rows' heads are not loaded, so an explicit depth is refused for them). Installed launches also carry the pinned inventory and typed verification mode from the saved policy; these are implementation arguments, not user setup choices. Omitted policy preserves the legacy ordinary contract. Unsupported model, memory, backend, startup and conflicting speculative controls are refused before serving.

Code: `libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/Startup/WorkerConfiguration.swift` (`WorkerConfiguration`) and `provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementTensorAssistantSelection.swift` (`readAutomatic`).

### `cluster stop`: failed retirement

On a paired leader, `darkbloom cluster stop --service` waits for its owned part to retire
before asking the member to stop and removing the local login service. A local
retirement timeout exits with status 1 and prints the pair's reason (a runtime
failure, not a usage error, so no usage text follows), and retains the login service
and saved stopped intent. Run the command again after the reported condition clears;
retries repeat the drain/acknowledgement path. An already stopped local part does not
require another model load.

When this Mac has stopped serving but the other Mac does not answer (its cluster
service is already off, or the cable is down), this Mac's service still stops and
leaves login, and the command exits 0. It says what happened on each Mac:
`This Mac stopped serving.`, `The other Mac (…) did not answer (…), so it was not
asked to stop (its cluster service may already be off).`, the service line, and
a last line to run `darkbloom cluster stop --service` on the other Mac if its
service is still on. A stop forwarded from the Mac that follows to the leading
Mac that cannot finish still exits 1 and keeps this Mac's service.

When the other Mac is gone for good (wiped, sold, or no longer cabled),
`darkbloom cluster stop --local-only` stops only this Mac. It skips the drain and
the member acknowledgement, removes the login service, and says that the other Mac
was not asked to stop. If that Mac comes back, run `darkbloom cluster stop --service`
there too.

Source: `provider-swift/Sources/darkbloom/ClusterServiceCommand.swift`
(`Cluster.Stop.finishStop`). See [planned stop ordering](../architecture/inference.md#planned-cluster-stop-ordering)
for the bounds and process custody rules.

Qwen3.8 27B automatic cluster capacity changes keep the current tensor split and native request execution path. Widening occurs only when the complete reservation fits that split; otherwise the current capacity remains available. No additional command or user setting is required. Implementation: `DistributedAutomaticBatchPlanner` and `ClusterPlacementFlow` in `provider-swift/Sources/ProviderCore/Inference/Distributed/`.
