# Set up Darkbloom with an AI agent

> Last updated: 2026-11-04

This page is a setup prompt for an AI agent. The agent installs Darkbloom,
logs in with the person's help, makes one Mac (or two Macs joined by one
Thunderbolt 5 cable) serve through Darkbloom, and then proves that it serves.
To use it, tell your agent: "Read
https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/agent-setup.md
and set up Darkbloom on this Mac" (or "on these two Macs"). It describes
provider 0.10.8. People can follow it too.

## How to use this page

You are the agent. Work from top to bottom:

1. Read the [rules](#rules-for-the-agent). Then tell the human which
   [actions only they can do](#what-only-the-human-can-do) and when each one comes up.
2. Each step gives the command, what success looks like and what to do if it
   fails. **STOP** means: tell the human what you see, ask the question, and
   wait for the answer before you go on.
3. Darkbloom's own messages name the fix, so quote them to the human word for
   word. If the screen says something this page does not, trust the screen and ask.
4. Keep a log: each command, which Mac it ran on, and its result. At the end,
   give the log to the human together with the [verification](#verify-it-really-serves) results.

Run each command in a shell on the Mac it is for. Right after a fresh install,
your shell may not find `darkbloom` yet. Run
`export PATH="$HOME/.darkbloom/bin:$PATH"` first.

## Prerequisites

### Rules for the agent

1. Never turn off or weaken SIP, Secure Boot, FileVault, Gatekeeper, the
   firewall or any other security setting, and never ask the human to.
2. Never edit, move or delete Darkbloom's files by hand. They include
   `~/.darkbloom`, `~/.config/darkbloom`, `~/Library/LaunchAgents/io.darkbloom.*`
   and the model folders. Use `darkbloom` commands. Reading logs is fine.
3. Never delete Keychain items. Darkbloom keeps its Secure Enclave and App
   Attest keys there, and deleting them breaks Apple's verification and the pairing.
4. Never run `darkbloom cluster link --remove` or `darkbloom cluster pair
   --forget` unless the human asks for exactly that. They undo the cable port
   setup and the pairing.
5. Ask the human before any download or copy of more than 20 GB on a Mac, and
   before any download that would leave less than 20 GB free on that Mac's disk.
6. Never type, read or store the human's macOS password, Darkbloom sign-in,
   API keys or tokens. The human types passwords into macOS's own prompt (or
   into `sudo`). Keep keys out of logs and messages.
7. Never answer the pairing code question yourself. Never accept the Terms of
   Service for the human.
8. While a Mac waits for Apple's verification ([App Attest](#troubleshooting)),
   don't restart it, kill a Darkbloom process, or run `darkbloom restart`,
   `stop` or `update`.
9. Install only the official release ([step 1](#1-install-or-update-darkbloom-every-mac)).
   Never install a local build, `darkbloom-dev`, or an app copied from another Mac.
10. Use `sudo` only where a Darkbloom message asks for it, and let the human type the password.
11. On a two-Mac pair, use `darkbloom cluster` and `darkbloom cluster stop` to
    manage it. Don't use `darkbloom start`, `stop` or `restart` there.

### What only the human can do

Tell the human about these at the start.

| Action | When | What the human does |
|---|---|---|
| Agree to the Darkbloom Terms of Service | Before the first start ([step 3](#3-one-mac-choose-a-model-and-start-serving) or [step 7](#7-two-macs-start-and-read-the-result)) | Reads https://darkbloom.dev/terms.html. Starting the provider counts as accepting them |
| Darkbloom login | [Step 2](#2-log-in-and-check-the-mac-every-mac), on each Mac | Opens the URL that `darkbloom login` prints, signs in, and enters the code it prints |
| Turn on RDMA over Thunderbolt (two Macs) | [Step 4](#4-two-macs-connect-the-cable-and-check-the-link), once per Mac, as an administrator | On macOS 27: System Settings › Privacy & Security › RDMA over Thunderbolt, then restart. On macOS 26: starts the Mac in Recovery, runs `rdma_ctl enable` in Terminal, then restarts |
| Plug in the cable (two Macs) | Step 4 | Connects one Thunderbolt 5 cable directly between a Thunderbolt 5 port on each Mac, with no dock or hub |
| macOS administrator password for the cable port | [Step 5](#5-two-macs-pair-them), once per Mac | Types it into macOS's prompt. Over SSH, types it into `sudo` in that terminal |
| Confirm the pairing code | Step 5 | Checks that both screens show the same six digits, then chooses **Yes** on each Mac |
| Local Network permission | Step 5, right after pairing, on each Mac | Clicks **Allow** on the macOS prompt for Darkbloom |
| Choose the model | Step 3 or [step 6](#6-two-macs-choose-the-model-on-the-leader) | Picks from the list that you read out |
| Screen Sharing (headless Macs) | Any macOS prompt, and the login session | macOS prompts appear only on the Mac's own screen, so the human opens it with Screen Sharing. Apple's App Attest also needs someone logged in to the Mac's desktop |
| Log in to macOS after a restart or power cut | Any time | Logs in on that Mac. With FileVault on, the disk stays locked until then, and Darkbloom serves again only after that |
| Run `darkbloom cluster` in Terminal | Steps 5–7 | It needs a terminal window. Without one it prints "Run `darkbloom cluster` in a Terminal window on this Mac." |
| Optional: a Darkbloom API key | [Verify](#a-test-request-through-darkbloom) | Creates a key in the console and puts it in your environment as `DARKBLOOM_API_KEY` |

### What each Mac needs

| Need | One Mac | Two Macs |
|---|---|---|
| Mac | Apple silicon (`uname -m` prints `arm64`) | Two Macs, each with a Thunderbolt 5 port. Different chips are fine (for example M3 Ultra + M5 Max) |
| macOS | 27 or later for a new install. The installer refuses older versions ("needs macOS 27 or later for new providers") | 27 or later on both. RDMA over Thunderbolt itself needs 26.2 or later |
| Memory | At least the `≥ N GB RAM` that `darkbloom models catalog` shows for the model. `darkbloom start` refuses Macs with less than 8 GB | Each Mac's free memory must hold its share of the model. If it can't, the model list says "does not fit now" |
| Disk | The `~N GB` from `darkbloom models catalog`, plus room for the prompt cache | The whole model on each Mac: the leader downloads it once and copies it to the other Mac over the cable. A model that Darkbloom already downloaded on that Mac is cloned and uses no new space |
| Cable | — | One Thunderbolt 5 cable, connected directly |
| Account | A Darkbloom account | Both Macs logged in to the same account |
| Network | Outbound HTTPS to `api.darkbloom.dev` (port 443). No inbound port | The same on both Macs |
| Darkbloom | 0.10.8 or later, the signed release | The same version on both Macs |

The full facts are in [hardware requirements](hardware-requirements.md) and
[what a pair needs](two-mac-cluster.md#what-you-need).

## Steps

### 1. Install or update Darkbloom (every Mac)

1. Check what is installed:

   ```bash
   ~/.darkbloom/bin/darkbloom --version 2>/dev/null || echo "not installed"
   ```

2. If it is not installed, run the official installer. It does not need `sudo`.

   ```bash
   curl -fsSL https://api.darkbloom.dev/install.sh | bash
   export PATH="$HOME/.darkbloom/bin:$PATH"
   ```

   Success ends with `Install complete` and `Installed: Darkbloom v<version> in
   <home>/.darkbloom`. If it fails, it prints `✗` and the reason, and often
   `Existing installation was left unchanged.` Quote it to the human
   ([installer exits](troubleshooting.md#installer-exits)) and don't retry it in a loop.

3. If it is installed, update it:

   ```bash
   darkbloom update
   ```

   Success: `Updated: v<old> -> v<new>` or `Already up to date (v<version>).`
   On a paired Mac, the update also restarts the pair together with the other
   Mac. Run it on both Macs.

4. Check that this is the signed release and not a local build:

   ```bash
   darkbloom --version
   codesign -dv ~/.darkbloom/Darkbloom.app 2>&1 | grep -E '^(Identifier|TeamIdentifier|Signature)='
   codesign --verify --deep --strict \
     -R='anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"' \
     ~/.darkbloom/Darkbloom.app && echo signature OK
   ```

   Success: version 0.10.8 or later, `Identifier=io.darkbloom.provider`,
   `TeamIdentifier=SLDQ2GJ6TL` and `signature OK`. `Signature=adhoc` or
   `TeamIdentifier=not set` means a local build. A local build may not use
   Darkbloom's production service, and `darkbloom update` can still report it
   as up to date. **STOP**: tell the human. With their go, run the installer
   from 1.2. The signed app has its own Secure Enclave key, so if this Mac was
   paired before, the two Macs pair again in [step 5](#5-two-macs-pair-them).
   On a version below 0.10.8, see [older builds](#older-builds).

   With two Macs, both must show the same version. If `darkbloom update`
   can't bring them to the same version, **STOP** and ask.

### 2. Log in and check the Mac (every Mac)

1. **STOP**: tell the human that a URL and a code are coming and that they
   should approve them in their browser. Then run:

   ```bash
   darkbloom login
   ```

   It prints `To link this machine, open this URL in your browser:`, the URL,
   `Then enter this code:`, the code and `Waiting for approval (expires in N
   minutes)...`, and then waits. Give the human the URL and the code. Success
   is `Account linked successfully!`. Run it somewhere that can wait that long,
   or ask the human to run it in Terminal. If the code expires, the command
   fails with an error, and you run it again. With two Macs, log both in to the same account.

2. Check the Mac:

   ```bash
   darkbloom doctor
   ```

   It prints `READINESS: …`, then sections of `[PASS]`, `[WARN]` and `[FAIL]`
   lines with `↳ fix:` hints under them, then `DETAILED CHECKS`. It exits with
   status 1 when any check fails. Read every `[FAIL]` and `[WARN]`:

   - Before the first start, `Daemon: NOT running` and the warnings that come
     from it are normal. Don't stop for them.
   - `[PASS] account link: auth token present` means the login worked.
     `[WARN] account link: not logged in` means 2.1 did not finish.
   - The top lines should read `Build: prod` and `Coordinator:
     wss://api.darkbloom.dev/ws/provider`. If they say anything else, **STOP** and ask.
   - A `[FAIL]` about SIP or boot security: **STOP**, tell the human what it
     says, and never change the setting yourself (rule 1).
   - A `[FAIL] cluster localLinkIsolation…` line: see [troubleshooting](#troubleshooting).

3. **STOP** for the Terms of Service, if the human has not agreed yet. Then
   go to step 3 (one Mac) or step 4 (two Macs).

### 3. One Mac: choose a model and start serving

1. List the models and this Mac's memory and free disk:

   ```bash
   darkbloom models catalog
   darkbloom status | grep '^Hardware:'
   df -h ~
   ```

   Each catalog line reads `✓ <name>  [<id>]  ~<size> GB (≥ <RAM> GB RAM)`. A
   `✓` means the model is already downloaded. Extra lines under a model say
   when this Mac can't run it. The models that fit are the ones whose RAM
   figure is at most this Mac's memory and whose size fits the free disk.

2. **STOP**: show the human the models that fit and ask which one to serve.
   Rule 5 applies to the download.

3. If the model has no `✓`, download it:

   ```bash
   darkbloom models download <id>
   ```

   Success: `Cached at <folder>`. Each file is checked against the catalog.

4. Start serving:

   ```bash
   darkbloom start --model <id>
   ```

   `--model` skips the interactive picker. The command starts a background
   service, and the service starts again at every login. By default an idle
   model is unloaded after 60 minutes and loads again on the next request.
   `--idle-timeout 0` keeps it loaded. Ask the human whether that matters to them.

5. Go to [verify](#one-mac).

### 4. Two Macs: connect the cable and check the link

1. **STOP**: ask the human which Mac should lead. The Mac where
   `darkbloom cluster` runs first becomes the leader and stays the leader: it
   chooses the model, and requests enter the pair there. Then ask the human to
   connect the cable.
2. Check the link on each Mac. This command changes nothing:

   ```bash
   darkbloom cluster link
   ```

   It prints `Local link: <state>`, one line per Thunderbolt RDMA port and what to do:

   | State | Meaning | Do |
   |---|---|---|
   | `ready` | The port is set up | Go on |
   | `portWithoutIPv4Address`, `portBridgedWithoutAddress` | The cable is seen, but the port is not set up for the cluster yet | Go on. Step 5 sets the port up after the password prompt |
   | `noActivePort` | No Thunderbolt RDMA port is up | **STOP**: the human connects the cable directly between Thunderbolt 5 ports |
   | `rdmaDisabled` | RDMA over Thunderbolt is off | **STOP**: an administrator turns it on (the message says how for this macOS version) and restarts the Mac |
   | `rdmaUnavailable` | This Mac or its macOS version has no RDMA | **STOP**: a pair needs Thunderbolt 5 and macOS 26.2 or later |
   | `gidNotPublished`, `probeFailed` | The cable is not ready | **STOP**: the human reconnects the cable or restarts the Mac. Then check again |

3. Both Macs need free memory for the pair, and a model that single-Mac
   serving has loaded uses memory. If `darkbloom status` on either Mac shows
   `Daemon: running` and lists warm models, **STOP** and ask the human whether
   to stop single-Mac serving there with `darkbloom stop` before the pair starts.

### 5. Two Macs: pair them

`darkbloom cluster` is interactive and needs a terminal. Without one, it
prints ``Run `darkbloom cluster` in a Terminal window on this Mac.`` and exits
with status 1. So the human runs it in Terminal on each Mac and reads the
screen to you, or pastes it. If you have a real interactive terminal on that
Mac, you may run `NO_COLOR=1 darkbloom cluster` there yourself: it then prints
plain lines and numbered choices. Even then, the pairing code and every macOS
prompt are the human's (rules 6 and 7). The screen has four steps:
**1/4 Connect**, **2/4 Pair**, **3/4 Model** and **4/4 Start**
([details](two-mac-cluster.md#the-steps-once)).

1. On the leader, run `darkbloom cluster`. It shows `1/4 Connect` and `Allow
   macOS's password and Local Network prompts.`. macOS then asks once for the
   administrator password to set up the cable port, and the human types it.
   Next come `✓ Cable ready`, `2/4 Pair` and ``Run `darkbloom cluster` on the
   other Mac.``. The leader then waits.
2. On the other Mac, run `darkbloom cluster`. The same password prompt
   appears there. Then both screens show `Code 123 456. Same on the other
   Mac?`. **STOP**: the human compares the two codes and chooses **Yes** on
   each Mac only if they match, or **No** if they don't. Enter selects
   **Yes**, so never press Enter for the human.
3. The screens say `✓ Paired. This Mac leads.` and `✓ Paired. The other Mac
   leads.`. Both Macs then ask for Local Network access for Darkbloom ("Click
   Allow on the Local Network prompt for Darkbloom. Allow it on the other Mac
   too."). The human clicks **Allow** on each Mac, and each screen shows
   `✓ Allowed`. Over SSH, the prompt appears on the Mac's own screen, so the
   human uses Screen Sharing.
4. The other Mac ends with `Done here: the other Mac chooses the model, and
   its screen shows whether the cluster serves. You can close this window.`.
   Everything after this happens on the leader. <!-- 0.10.8: confirm after merge -->

If ``Cable port not set up. Run `darkbloom cluster` again.`` appears, the
password prompt was declined or failed. Run `darkbloom cluster` again with
the human at the Mac. If one Mac waits at `2/4 Pair` while the other only
shows its status, that Mac still holds an old pairing. See
[troubleshooting](#troubleshooting).

### 6. Two Macs: choose the model (on the leader)

`3/4 Model` shows `Reading both Macs over the cable` and `Planning each model
for both Macs`, then a list. The list has only the models approved for
clusters (GLM-5.3-Flash, Qwen3.8 27B, MiMo-V2.6-Flash and Gemma 4 26B QAT)
that these two Macs can serve. Each line gives the name, size and split, for
example `Qwen3.8-27B-4bit-mtp · 16.3 GB · pipeline`. A line ends with `copy`
or `download` when one Mac lacks the model. It ends with `does not fit now`,
and comes last, when free memory is short right now.

Tell the human how the split works, and don't override it:

- **Tensor parallel** splits every layer across both Macs. Each Mac holds
  half of every layer, and both work on every token.
- **Pipeline** gives each Mac a share of the layers. A request passes through
  one Mac's layers, then the other's.
- The planner picks, for each model, the fastest measured mode that keeps
  every feature. Qwen and GLM use tensor parallel wherever it fits. Gemma 4
  and MiMo stay on pipeline until tensor parallel has been measured faster on
  both Macs. <!-- 0.10.8: confirm after merge -->
- Mixed pairs, such as M3 Ultra + M5 Max, are supported. The chip doesn't
  decide anything. Each Mac's free memory decides what it holds, and a pair
  served through Darkbloom gets equal shares
  ([how the split is chosen](two-mac-cluster.md#how-the-split-is-chosen)).

1. **STOP**: read the list to the human and ask which model to serve. Enter
   selects the first line. Rule 5 applies: a `download` model is downloaded on
   the leader and then copied, so it takes its full size on each Mac.
2. If the model still has to reach a Mac, a second list offers `Download`,
   `Copy to the other Mac (about N s)` or `Copy from the other Mac`, and
   `Cancel`. Enter selects the first. Progress is shown, and an interrupted
   copy resumes.
3. ``Can't start <model>: <reason>. Free space, then run `darkbloom cluster`
   again.`` means there is not enough disk space. **STOP**.

### 7. Two Macs: start, and read the result

`4/4 Start` runs on the leader:

1. Login check. Any Mac without a Darkbloom login is named before anything
   starts: `This Mac and the other Mac (…) aren't logged in to Darkbloom, so
   the coordinator won't pair them.`. The choices are **Log in on this Mac**
   (or **Check again**, once `darkbloom login` has run on the other Mac),
   **Serve locally only** and **Cancel**. Log the Mac in as in step 2, then
   check again. Choose **Serve locally only** only if the human wants no
   Darkbloom traffic. <!-- 0.10.8: confirm after merge -->
2. `Loading takes a few minutes for a large model; both Macs show progress
   here.` Rows for each Mac (registering, registered, loading its share) show
   the time since loading began. Wait, and don't touch either Mac. <!-- 0.10.8: confirm after merge -->
3. The result appears between two rules. Success looks like this: <!-- 0.10.8: confirm after merge -->

   ```text
   ────────────────────────────────────────────────
   ✓ Serving Qwen3.8-27B-4bit-mtp through Darkbloom on both Macs (pipeline)
     No local API: requests reach the pair through Darkbloom
     Test response in 0.84 s
   ────────────────────────────────────────────────
   Done. You can close both windows.
   Run `darkbloom cluster` again to manage it.
   ```

   A failure looks like this, followed by the choices **Retry**, **Change
   model**, **Serve locally only** and **Diagnostics**: <!-- 0.10.8: confirm after merge -->

   ```text
   ────────────────────────────────────────────────
   ✗ Not serving: <reason>.
     <what to do>
   ────────────────────────────────────────────────
   ```

   Act on the reason ([troubleshooting](#troubleshooting)), then choose
   **Retry**. Pressing q leaves with ``Not serving yet. Both Macs keep trying by
   themselves; run `darkbloom cluster` to check.`` and exit status 1.
4. Go to [verify](#two-macs).

## Verify it really serves

Never report success because a start command finished. `Registered with the
coordinator as a cluster member` alone does not mean serving: the coordinator
still has to pair both Macs, and both have to load the model. Before 0.10.8,
the setup could even say `✓ Serving … Done.` with nothing loaded.

### One Mac

```bash
darkbloom status
darkbloom doctor
```

The Mac serves when `darkbloom status` shows all of these lines:

- `Daemon: running (pid …, up …)`
- `Traffic: eligible for coordinator work (…)`, for example `(App Attest
  authorized until 14:05; renewed automatically)`
- `Warm models:`, naming the model. An idle model unloads after the idle
  timeout and loads again on the next request.

In the first minutes after a start, `Traffic: not yet eligible (…)` is
normal. Check again every few minutes without restarting anything (rule 8).
If it is still there after 15 minutes, read doctor's `APP ATTEST` lines
([troubleshooting](#troubleshooting)). `Traffic: NOT receiving coordinator
work: …` comes with a `→ fix:` line: follow it. Then send a
[test request](#a-test-request-through-darkbloom).

### Two Macs

Check all four:

1. The step 7 result block starts with `✓ Serving`. <!-- 0.10.8: confirm after merge -->
2. Run `darkbloom cluster` on the leader again, in a terminal. Its status line
   must say `Serving <model> through Darkbloom on both Macs (<split>).`. It
   must not say `<model> is not serving yet: <reason>.` or `Stopped; …`.
   Press q to leave; Enter would pick the first menu item. <!-- 0.10.8: confirm after merge -->
3. Run these yourself. They only read:

   ```bash
   grep '^Pair: ' ~/.darkbloom/cluster-setup/rank.log | tail -n 1   # on the leader
   darkbloom status | grep '^Cluster service'                       # on each Mac
   ```

   On the leader, `Pair: serving (first request in … s)` means both Macs
   loaded the model and the pair answered a request. `Pair: starting` means it
   is still loading. `Pair: stopped (<reason>)` says why it stopped. <!-- 0.10.8: confirm after merge -->
   On each Mac, the status should say `Cluster service: running; starts at login`.
4. A [test request](#a-test-request-through-darkbloom) answers.

### A test request through Darkbloom

You need a Darkbloom API key from the same account. The human creates it in
the console and puts it in your environment as `DARKBLOOM_API_KEY`. Never
print it. The `X-Darkbloom-Route: self` header sends the request only to Macs
of that account:

```bash
curl -sS https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer $DARKBLOOM_API_KEY" \
  -H "X-Darkbloom-Route: self" \
  -H "Content-Type: application/json" \
  -d '{"model":"<id>","messages":[{"role":"user","content":"Say hi"}],"max_tokens":32}'
```

`<id>` is the model's catalog ID, shown in brackets by `darkbloom models catalog`.
A reply with `choices` is a success. The errors mean:

- `503 model_not_loaded`: no Mac of this account serves that model right now.
- `503 machine_offline`: no Mac of this account is connected.
- `409 no_linked_machine`: the key's account has no logged-in Mac.

The test proves that the pair serves only if no other Mac of the account
serves the same model. See [self-route](self-route.md) for more. A pair that
serves locally only (`darkbloom cluster local`) has an API on the leader
instead: choose **Test** in `darkbloom cluster` there.

## Manage it later

| To | On | Do |
|---|---|---|
| Change the pair's model | The leader | `darkbloom cluster` → **Change model**. It stops both Macs, waits for their memory to be freed, then plans the model again |
| Stop the pair | The leader | `darkbloom cluster` → **Stop**, or `darkbloom cluster stop`. `cluster stop` stops the pair and keeps this Mac's cluster service from starting at login; `darkbloom cluster` starts it again |
| Stop one Mac whose partner is gone for good | That Mac | `darkbloom cluster stop --local-only` |
| Serve locally only, with no Darkbloom traffic | The leader | `darkbloom cluster` → **Serve locally**, or `darkbloom cluster local`. **Serve through Darkbloom** switches back. The choice stays after restarts <!-- 0.10.8: confirm after merge --> |
| Start over and pair again | Either Mac | `darkbloom cluster` → **Start over (pair again)** → **Yes, start over**. Then run `darkbloom cluster` on the other Mac and choose **Pair again** if it asks <!-- 0.10.8: confirm after merge --> |
| Update | Every Mac | `darkbloom update` on each Mac, and the pair restarts together. Automatic updates are on by default |
| Check that both Macs freed their memory | The leader | `darkbloom cluster` → **Check memory is freed** |
| Change, stop or restart a single Mac | That Mac | `darkbloom start --model <id>`, `darkbloom stop`, `darkbloom restart`. These are for single Macs only (rule 11) |

On the Mac that follows, `darkbloom cluster` shows the status and ``This Mac
follows the other Mac (<name>): to choose or change the model, run `darkbloom
cluster` on that Mac.``. It offers **Start over (pair again)** and **Quit**,
and Enter quits. <!-- 0.10.8: confirm after merge -->

## Uninstall

In 0.10.8, `darkbloom uninstall` takes Darkbloom off one Mac in one of two ways: <!-- 0.10.8: confirm after merge -->

| Choice | Flag | Removes | Keeps |
|---|---|---|---|
| Remove everything | `--everything` | The app, settings, pairing, logs and every model Darkbloom downloaded. It says how much space it freed | Models in folders the human chose (an external drive, for example) and Keychain keys <!-- 0.10.8: confirm after merge --> |
| Keep models | `--keep-models` | Everything else, including settings and the pairing, so a reinstall starts clean and reuses the models | The models Darkbloom downloaded <!-- 0.10.8: confirm after merge --> |

Both choices stop serving gracefully, remove Darkbloom's background services,
unpair the Mac, undo the cable port setup (macOS asks for the administrator
password) and remove the `darkbloom` command link. Without a terminal, the
command needs a choice and `--yes`. <!-- 0.10.8: confirm after merge -->

1. **STOP**: ask the human which choice they want, and show them the plan first.
   `--dry-run` changes nothing:

   ```bash
   darkbloom uninstall --everything --dry-run    # or --keep-models --dry-run
   ```

2. With the human's go:

   ```bash
   darkbloom uninstall --everything --yes        # or --keep-models --yes
   ```

3. On a paired Mac, the last line is about the other Mac: run `darkbloom
   uninstall` there too, or run `darkbloom cluster` there to pair it with
   another Mac.

## Troubleshooting

| Signal | Cause | Do |
|---|---|---|
| The console says the Mac is waiting for verification, or `✗ Not serving: <Mac> isn't verified by Apple yet; Darkbloom retries by itself at about HH:MM. Don't restart either Mac until then.` <!-- 0.10.8: confirm after merge --> | Apple's App Attest has not verified that Mac yet, and the coordinator pairs only verified Macs | Run `darkbloom doctor` on that Mac. If `app attest key — no usable key; the local key-generation safeguard clears in <time>` appears, wait that long. Don't restart, stop or start anything, and don't delete Keychain items. Then choose **Retry**, or run `darkbloom cluster` once on the leader, and leave both Macs alone for 5 minutes. From 0.10.8, a stop or a lost connection during Apple's call keeps the attestation, but a crash or a forced kill still blocks a new key for up to an hour <!-- 0.10.8: confirm after merge --> |
| doctor: `[FAIL] cluster localLinkIsolation.rdma_enN: clusterSubnetInUse: The cluster port enN cannot be isolated yet (the cluster subnet 10.219/16 is already used on this Mac) …`, on a version below 0.10.8 | A known false alarm on paired Macs | Don't stop for it, and never run `darkbloom cluster link --remove` because of it. Verify serving instead, and update both Macs. 0.10.8 no longer reports it. <!-- 0.10.8: confirm after merge --> |
| The same `[FAIL]` on 0.10.8 or later | Another interface or a VPN on this Mac uses 10.219/16 | **STOP**: show the human the line. They remove that address or VPN route, then run `darkbloom cluster` again |
| One Mac waits at `2/4 Pair` while the other only shows its status; `The other Mac doesn't answer over the cable: …`; `This Mac's Secure Enclave key changed after it paired …` | An old pairing: a Mac was reinstalled, unpaired or replaced, or moved between apps | Choose **Pair again** on the Mac that offers it, then pair as in step 5. On the other Mac, choose **Pair again** if it asks ([pairing again](two-mac-cluster.md#when-something-is-in-the-way)) <!-- 0.10.8: confirm after merge --> |
| `… doesn't fit in free memory now: Quit apps on … first.`, a list line ending `does not fit now`, or `✗ Not serving: <Mac> lacks free memory for its share` | That Mac's free memory can't hold its share | **STOP**: ask the human to quit apps (or stop single-Mac serving) on that Mac, then **Retry**. Or choose a smaller model. Never change memory settings to force a fit <!-- 0.10.8: confirm after merge --> |
| `No approved model can run on these Macs now.` | No approved model fits these Macs or is supported on them | Read the reasons it prints, then **STOP** |
| `… aren't logged in to Darkbloom …` or `[WARN] account link: not logged in` | No Darkbloom login on that Mac | Run `darkbloom login` on that Mac (step 2), then **Check again** or **Retry** <!-- 0.10.8: confirm after merge --> |
| `A part keeps ending the same way: …` | One Mac's part keeps failing at start | Choose **Diagnostics**, which saves a redacted file in the home folder. Then [report it](#report-a-problem) <!-- 0.10.8: confirm after merge --> |
| ``Run `darkbloom cluster` in a Terminal window on this Mac.`` | It ran without a terminal | Ask the human to run it in Terminal (step 5) |
| `Traffic: NOT receiving coordinator work: …` with `→ fix: …` | The coordinator doesn't route work to this Mac | Do what the fix line says |
| Anything else, or no progress | — | [Report it](#report-a-problem) |

### Report a problem

**STOP** and ask before you upload anything. `darkbloom report` uploads this
Mac's recent Darkbloom logs and App Attest evidence to Darkbloom, and
`darkbloom report --dry-run` prints what it would send. A successful upload
ends with `Report ID: <n>`: give that number to the human. macOS lets only
administrator accounts read the system log, so on a standard account the
human may run `sudo darkbloom report`.

### Older builds

Below 0.10.8, update every Mac first with `darkbloom update`. If no newer
release is offered yet:

- The setup can say `✓ Serving … Done.` with nothing loaded. Always verify as above.
- The `localLinkIsolation` `[FAIL]` above is a false alarm.
- There is no **Pair again** or **Start over**. **STOP** and ask. The manual
  way is `darkbloom cluster pair --status`, then `darkbloom cluster pair
  --forget <pin>` on the Mac with the old pairing, and only if the human asks for it (rule 4).
- There is no `darkbloom uninstall`. Don't delete files by hand; ask the human.

## Related

- [Installation](installation.md) and [quickstart](quickstart.md)
- [Two Macs as one provider](two-mac-cluster.md) and [always-on cluster members](cluster-always-on.md)
- [Troubleshooting](troubleshooting.md), [attestation](attestation.md) and the [CLI reference](cli-reference.md)
- [Self-route](self-route.md) and [hardware requirements](hardware-requirements.md)

Code that prints the lines quoted here:

| Lines | Code |
|---|---|
| Installer steps and refusals | `scripts/install.sh` |
| `darkbloom cluster` without a terminal | `provider-swift/Sources/darkbloom/ClusterSetupWizardCommand.swift` (`needsTerminalLine`) |
| doctor markers and the `account link` check | `provider-swift/Sources/darkbloom/Diagnostics/DiagnosticReportRenderer.swift`, `provider-swift/Sources/darkbloom/DoctorCommand.swift` |
| `app attest key` and the key-generation safeguard | `provider-swift/Sources/ProviderCore/Diagnostics/AppAttestLocalDiagnosis.swift` |
| `Traffic:` lines | `provider-swift/Sources/darkbloom/StatusCommand+Traffic.swift` |
| `Local link:` states | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkReadinessState.swift` |
| Models approved for clusters, and the tensor-parallel and pipeline placements | `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift` (`declared`, `placement`) |
| The setup's steps, code question and menus | `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterOnboardingFlow.swift` |
