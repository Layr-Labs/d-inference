# Set up Darkbloom with an AI agent

> Last updated: 2026-11-11

This page is a setup prompt for an AI agent. The agent installs Darkbloom,
logs in with the person's help, makes one Mac (or two Macs joined by one
Thunderbolt 5 cable) serve through Darkbloom, and then proves that it serves.
To use it, tell your agent: "Read
https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/agent-setup.md
and set up Darkbloom on this Mac" (or "on these two Macs"). It describes
provider 0.10.8. People can follow it too. Testers who set up DevNet,
Darkbloom's testing network, use the same steps with the
[DevNet names](#devnet-testers-only).

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
`export PATH="$HOME/.darkbloom/bin:$PATH"` first (on DevNet,
`export PATH="$HOME/.darkbloom-dev/bin:$PATH"`).

Setting up a two-Mac pair needs a terminal and the human. Once the pair is
set up, three commands work from your shell without a terminal:
`darkbloom cluster status --json` (does it serve, and if not, why),
`darkbloom start` and `darkbloom stop`.

## Prerequisites

### Rules for the agent

1. Never turn off or weaken SIP, Secure Boot, FileVault, Gatekeeper, the
   firewall or any other security setting, and never ask the human to.
2. Never edit, move or delete Darkbloom's files by hand. They include
   `~/.darkbloom`, `~/.config/darkbloom`, `~/Library/LaunchAgents/io.darkbloom.*`
   and the model folders, and on DevNet `~/.darkbloom-dev` and
   `~/.config/darkbloom-dev`. Use `darkbloom` commands. Reading logs is fine.
3. Never delete Keychain items. Darkbloom keeps its Secure Enclave and App
   Attest keys there, and deleting them breaks Apple's verification and the pairing.
4. Never run `darkbloom cluster link --remove` or `darkbloom cluster pair
   --forget` unless the human asks for exactly that. They undo the cable port
   setup and the pairing, and the pair stops serving on both Macs. On a paired
   Mac, `link --remove` says so and asks `Remove it? [y/N]`: never answer for
   the human, and never add `--yes`.
5. Ask the human before any download or copy of more than 20 GB on a Mac, and
   before any download that would leave less than 20 GB free on that Mac's disk.
6. Never type, read or store the human's macOS password, Darkbloom sign-in,
   API keys or tokens. The human types passwords into macOS's own prompt (or
   into `sudo`). Keep keys out of logs and messages.
7. Never answer the pairing code question yourself. Never accept the Terms of
   Service for the human.
8. While a Mac waits for Apple's verification ([App Attest](#troubleshooting)),
   don't restart it, kill a Darkbloom process, or run `darkbloom start`,
   `stop`, `restart` or `update`. On a pair, each of these acts on both Macs.
9. Install only a signed release from Darkbloom's installer: the production one
   in [step 1](#1-install-or-update-darkbloom-every-mac), or the DevNet one when
   the human asked for DevNet ([DevNet](#devnet-testers-only)). Never install a
   local build or an app copied from another Mac.
10. Use `sudo` only where a Darkbloom message asks for it, and let the human type the password.
11. On a paired Mac, `darkbloom start`, `stop`, `restart` and `status` act on
    the pair, from either Mac, and say so in their first line: `darkbloom
    start` starts the pair whatever its state, also after `darkbloom stop`.
    Single-Mac options such as `--autopilot` or `--network` are refused there
    (exit status 64) without `--solo`. Without a terminal, `--model <id>`
    alone (as the desktop app's Start passes it) starts the pair with the
    pair's own model, and a last line says so when that isn't `<id>`. Add
    `--solo` only when the human wants single-Mac serving
    on this Mac alone: it is refused while the pair runs here. While the pair
    doesn't run here (stopped, or the other Mac gone), `darkbloom start --solo
    --model <id>` serves this Mac alone and says so first ([going back to
    serving on one Mac](two-mac-cluster.md#going-back-to-serving-on-one-mac)).
    No start asks anything without a terminal: one that doesn't name its
    models refuses in one line that says to add `--model <id>` or `--all`
    (exit status 64). On a paired Mac, `darkbloom status` says under the pair
    when the Mac serves alone instead.
12. Before `darkbloom cluster` on a pair, tell the human to be at both Macs'
    screens, or to open Screen Sharing to each Mac with no display (a Mac
    Studio, a MacBook with its lid closed): every macOS prompt of the setup
    (the cable port's password, Local Network's Allow, the pairing code's Yes)
    is on that Mac's own screen. Never run the setup, `darkbloom cluster link
    --fix` or `--remove`, or `darkbloom uninstall` on a pair Mac over SSH: macOS
    can't show its approval prompt there, and Darkbloom says so and stops
    (``macOS can't show its approval prompt over SSH. Run `darkbloom cluster` in
    Terminal on this Mac's own screen, or through Screen Sharing.``). Pass that
    on to the human; never choose "Go on over SSH" for them.

### What only the human can do

You can't click a macOS prompt, change System Settings, type a password, sign
in through a browser or see a Mac's screen. Tell the human about these at the
start, then ask for each one when it comes up and wait.

| Action | When | What the human does |
|---|---|---|
| Agree to the Darkbloom Terms of Service | Before the first start ([step 3](#3-one-mac-choose-a-model-and-start-serving) or [step 7](#7-two-macs-start-and-read-the-result)) | Reads https://darkbloom.dev/terms.html. Starting the provider counts as accepting them |
| Darkbloom login | [Step 2](#2-log-in-and-check-the-mac-every-mac), on each Mac | Opens the URL that `darkbloom login` prints in a browser, signs in, and enters the code it prints |
| Turn on RDMA over Thunderbolt (two Macs) | [Step 4](#4-two-macs-connect-the-cable-and-check-the-link), once per Mac, as an administrator | On macOS 27: System Settings → Privacy & Security → RDMA over Thunderbolt, then restart. On macOS 26: starts the Mac in Recovery, runs `rdma_ctl enable` in Terminal, then restarts |
| Plug in the cable (two Macs) | Step 4 | Connects one Thunderbolt 5 cable directly between a Thunderbolt 5 port on each Mac, with no dock or hub |
| macOS administrator password for the cable port | [Step 5](#5-two-macs-pair-them), once per Mac, only while the port isn't set up | Types it into macOS's prompt on that Mac's own screen (Screen Sharing on a Mac with no display). Not over SSH: macOS can't show its prompt there ([rule 12](#rules-for-the-agent)) |
| Confirm the pairing code | Step 5 | Checks that both screens show the same six digits, then chooses **Yes** on each Mac |
| Local Network permission | Step 5, right after pairing, on each Mac | At the Mac's own screen (Screen Sharing on a Mac with no display): System Settings → Privacy & Security → Local Network → turns on “Darkbloom” (the DevNet app is listed under that name too). With no such row, macOS has never asked on that Mac: it asks on that Mac's screen the next time the app dials over the cable, and the human clicks **Allow** there. If macOS's firewall is on, also lets Darkbloom accept incoming connections (System Settings → Network → Firewall) |
| Choose the model | Step 3 or [step 6](#6-two-macs-choose-the-model-on-the-leader), and when changing it later | Picks from the list that you read out |
| Screen Sharing (headless Macs) | Any macOS prompt, and the login session | macOS prompts appear only on the Mac's own screen, so the human opens it with Screen Sharing. Apple's App Attest also needs someone logged in to the Mac's desktop |
| Log in to macOS after a restart or power cut | Any time | Logs in on that Mac. With FileVault on, the disk stays locked until then, and Darkbloom serves again only after that. A pair serves only once both Macs are logged in |
| Run `darkbloom cluster` in Terminal | Steps 5–7, and later to change or test the pair's model (`darkbloom start` in a terminal opens the same screen) | It needs a terminal window. Without one it prints ``Run `darkbloom cluster` in a Terminal window on this Mac.`` |
| Optional: a Darkbloom API key | [Verify](#a-test-request-through-darkbloom) | Creates a key in the console and puts it in your environment as `DARKBLOOM_API_KEY` |

### What each Mac needs

| Need | One Mac | Two Macs |
|---|---|---|
| Mac | Apple silicon (`uname -m` prints `arm64`) | Two Macs, each with a Thunderbolt 5 port. Different chips are fine (for example M3 Ultra + M5 Max) |
| macOS | 27 or later for a new install. The installer refuses older versions ("needs macOS 27 or later for new providers") | 27 or later on both. RDMA over Thunderbolt itself needs 26.2 or later |
| Memory | At least the `≥ N GB RAM` that `darkbloom models catalog` shows for the model. `darkbloom start` refuses Macs with less than 8 GB | Each Mac must hold its share of the model with its apps closed, and the part of the share that sits on the GPU must fit macOS's GPU memory limit. The model list leaves out a model that can't fit. One that fits only once apps quit ends with "does not fit now" |
| Disk | The `~N GB` from `darkbloom models catalog`, plus room for the prompt cache | The whole model on each Mac, free now, plus 2.1 GB to spare. Space macOS could free later (local snapshots, for example) doesn't count, so Finder can show more than Darkbloom counts. The leader downloads the model once and copies it to the other Mac over the cable. A model that Darkbloom already downloaded on that Mac is cloned and uses no new space |
| Cable | — | One Thunderbolt 5 cable, connected directly |
| Account | A Darkbloom account | Both Macs logged in to the same account |
| Network | Outbound HTTPS to `api.darkbloom.dev` (port 443). No inbound port | The same on both Macs |
| Darkbloom | 0.10.8 or later, the signed release (DevNet: [its own numbering](#devnet-testers-only)) | The same version on both Macs |

The full facts are in [hardware requirements](hardware-requirements.md),
[what a pair needs](two-mac-cluster.md#what-you-need) and
[free disk for a pair](two-mac-cluster.md#free-disk).

### DevNet (testers only)

Skip this unless the human asked you to set up DevNet, Darkbloom's testing
network, which runs builds of the `dev` branch. A DevNet build is a separate
signed app that installs beside the production one. Follow every step on this
page with these names ([dev build identity](../operations/provider-release.md#dev-build-identity)):

| On this page | On DevNet |
|---|---|
| `darkbloom` | `darkbloom-dev` |
| `~/.darkbloom`, `~/.darkbloom/bin` | `~/.darkbloom-dev`, `~/.darkbloom-dev/bin` |
| `~/.darkbloom/Darkbloom.app` | `~/.darkbloom-dev/"Darkbloom Dev.app"` (quoted: the name has a space) |
| `curl -fsSL https://api.darkbloom.dev/install.sh \| bash` | `curl -fsSL https://api.dev.darkbloom.dev/install.sh \| bash` |
| `Installed: Darkbloom v<version> in <home>/.darkbloom` | `Installed: Darkbloom Dev v<version> in <home>/.darkbloom-dev` |
| doctor: `Build: prod`, `Coordinator: wss://api.darkbloom.dev/ws/provider` | `Build: dev`, `Coordinator: wss://api.dev.darkbloom.dev/ws/provider` |
| `https://api.darkbloom.dev/v1/chat/completions` | `https://api.dev.darkbloom.dev/v1/chat/completions` |
| Version 0.10.8 or later | `X.Y.Z-dev.branch.N`, for example `0.10.6-dev.branch.76` |

- **The version.** X.Y.Z is the `dev` branch's version number, which can lag
  the release: `0.10.6-dev.branch.76` carries the 0.10.8 code. Don't compare it
  with this page's release numbers; "0.10.8 or later" and
  [older builds](#older-builds) are for production builds. Both Macs need the
  same DevNet build (`darkbloom-dev update` brings the latest).
- **Separate from the production app on the same Mac:** the pairing, the
  cluster setup and its logs (`~/.darkbloom-dev/cluster-setup/`), the cluster
  service and its login job, the Secure Enclave key, login and settings. So
  pairing, **Start over**, `darkbloom-dev cluster stop --service` or
  `darkbloom-dev uninstall` leave the production app's pair as it is, and the
  reverse. **Shared:** the models and the cable port setup (one cable, one
  network setup), and one GPU: only one app's pair runs on a Mac at a time.
  While one app's pair (or its model check) uses the GPU, the other app's pair
  waits, and its status says ``<app> on this Mac holds this Mac's GPU …``. It
  starts by itself once the other app's pair stops, and a wait never counts as
  a failing pair. A DevNet build also waits while the production app serves on
  that Mac, whatever production's version, and its running pair stops when
  production starts serving there. Its single-Mac serving loads no model while
  production serves there either. **STOP** when a DevNet build says
  that the production Darkbloom holds the GPU or is serving: production serves
  on that Mac, so never stop it yourself; tell the human and wait. `cluster
  link --remove` in one app names the other app when that app still uses the
  port and asks first; `--yes` doesn't answer for it. A DevNet app updated
  from a build that shared the pairing shows the Mac as not paired: update both
  Macs, then pair the DevNet app again (step 5).
- **The DevNet installer** adds a `PATH` line to `~/.zshrc` and, where
  `/usr/local/bin` is writable, links `/usr/local/bin/darkbloom-dev`.
  `darkbloom-dev login` prints DevNet's own URL. A test request needs an API
  key from the same DevNet account.
- **The pair's local API port,** in both apps and for both pair choices
  (**Only me** and **Both, me first**): each Mac's own `[local] port`, the one
  its single-Mac local API takes (`LocalAPIPort.thisMac`). The Mac that runs
  the pair's API listens on its port, and the other Mac's port passes requests
  to it, so the two can differ. A Mac with no saved port keeps the port its
  local API already uses, else takes the first free one from 8001, never 8000,
  and saves it; a Mac updated from 0.10.10 keeps 8000. `darkbloom local` on
  each Mac says which, and so does the setup's card once the port is up. Each
  app keeps its own `provider.toml`, so the two apps' ports are separate. The
  ports the two Macs of a pair use on the cable are the DevNet app's own, so
  the two apps' pairs never answer each other.
- **The DevNet app names `darkbloom-dev`** in its screens, commands and hints,
  and the Local Network lines name “Darkbloom Dev”, but tell the human to turn
  on the row macOS lists, “Darkbloom”: both apps share one bundle ID. Type
  `darkbloom-dev`; the plain `darkbloom` command is the production app.

## Steps

### 1. Install or update Darkbloom (every Mac)

On DevNet, use the [DevNet names](#devnet-testers-only) in every command below.

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

   Success: version 0.10.8 or later (on DevNet, the
   [DevNet number](#devnet-testers-only)), `Identifier=io.darkbloom.provider`,
   `TeamIdentifier=SLDQ2GJ6TL` and `signature OK`. `Signature=adhoc` or
   `TeamIdentifier=not set` means a local build. A local build may not use
   Darkbloom's production service, and `darkbloom update` can still report it
   as up to date. **STOP**: tell the human. With their go, run the installer
   from 1.2. On a production version below 0.10.8, see [older builds](#older-builds).

   A newly installed app has its own Secure Enclave key, but it can take over
   the pairing another build of the same app made on this Mac (the signed
   release over a local build, or the reverse); the DevNet and production apps
   never share a pairing. After installing another build on a paired Mac, run
   `darkbloom cluster` on both Macs in [step 5](#5-two-macs-pair-them), and act
   on what each Mac shows. When it sees that the key changed, it says
   ``This Mac's Secure Enclave key changed after it paired (…), so the Macs
   must pair again to serve through Darkbloom.`` and offers only **Pair again**
   and **Quit**: choose **Pair again** on that Mac. If it shows the old pairing
   as usual instead, or says the other Mac isn't answering, choose
   **Start over (unpair and set up again)** → **Yes, start over** on that Mac.
   Either way, only with the human's go.

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
     from it are normal. Don't stop for them. On a Mac that is already paired,
     `Daemon: single-Mac serving off (this Mac serves in its two-Mac cluster)`
     and a `Cluster:` line are normal too.
   - `[PASS] account link: auth token present` means the login worked.
     `[WARN] account link: not logged in` means 2.1 did not finish.
   - The top lines should read `Build: prod` and `Coordinator:
     wss://api.darkbloom.dev/ws/provider` (on DevNet, `Build: dev` and
     `Coordinator: wss://api.dev.darkbloom.dev/ws/provider`). If they say
     anything else, **STOP** and ask.
   - A `[FAIL]` about SIP or boot security: **STOP**, tell the human what it
     says, and never change the setting yourself (rule 1).
   - A `[FAIL] cluster localLinkIsolation…` line: see [troubleshooting](#troubleshooting).
   - Before the first setup with this app, no cluster setup is saved, and
     doctor has no cluster `[FAIL]` for it (`darkbloom cluster doctor` says
     `Saved setup: notConfigured`). A setup saved in a file other users can
     open fails with ``[FAIL] cluster savedConfiguration: <file> saves this
     Mac's cluster setup, but other users can open it (mode 644); run `chmod
     600 <file>` (details: `darkbloom cluster doctor`)``. **STOP**: tell the
     human, and run that `chmod 600` command only with their go.

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
   service, and the service starts again at every login. Nothing asks how the
   Mac serves: on a Mac with no choice saved it serves **Both**, the Darkbloom
   network and this Mac's local API beside it, and Darkbloom keeps serving
   while the human uses the Mac. One line says so and the choice is saved:
   ``Serving Darkbloom and your local API at http://127.0.0.1:<port>/v1
   (`darkbloom local` for local only).`` A Mac with a saved choice serves it as
   saved. If the human wants another way, add it to the command instead:
   `--network` (Darkbloom only, no local API), `--me-first` (Darkbloom pauses
   while they use the Mac) or `--local` (only them; never Darkbloom). The
   human's own `darkbloom local` does the last one too, and prints the local
   API's key (rule 6: don't run it to read the key). Without a terminal it never
   stops Darkbloom on a Mac that serves it; in a terminal it asks first, and that
   answer is the human's.
   By default an idle model is unloaded after 60 minutes and loads again on the
   next request. `--idle-timeout 0` keeps it loaded. Ask the human whether that
   matters to them.

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

   It prints `Local link: <state>`, then one line per Thunderbolt RDMA port:

   ```text
   Local link: ready
     rdma_en1 (en1): noActivePort · port down
     rdma_en6 (en6): ready · port active · own IPv4 address · IPv4-mapped GID published · isolated: own network service, fixed address, no bridge, router or DNS
     rdma_en2 (en2): noActivePort · port down
   ```

   Act on the state in the first line. A port without the cable says
   `noActivePort · port down`, which is normal when the first line is `ready`.

   | State in the first line | Meaning | Do |
   |---|---|---|
   | `ready` | The port is set up | Go on |
   | `portWithoutIPv4Address`, `portBridgedWithoutAddress` | The cable is seen, but the port is not set up for the cluster yet | Go on. Step 5 sets the port up after the password prompt |
   | `noActivePort` | No Thunderbolt RDMA port is up | **STOP**: the human connects the cable directly between Thunderbolt 5 ports |
   | `rdmaDisabled` | RDMA over Thunderbolt is off | **STOP**: an administrator turns it on (the message says how for this macOS version) and restarts the Mac |
   | `rdmaUnavailable` | This Mac or its macOS version has no RDMA | **STOP**: a pair needs Thunderbolt 5 and macOS 26.2 or later |
   | `gidNotPublished`, `probeFailed` | The cable is not ready | **STOP**: the human reconnects the cable or restarts the Mac. Then check again |

3. Both Macs need free memory for the pair, and a model that single-Mac
   serving has loaded uses memory. Run `darkbloom status --solo` on each Mac
   (on a paired Mac, plain `darkbloom status` shows the pair instead). On a
   paired Mac, go on when it prints ``Single-Mac serving: off (this Mac serves
   in its two-Mac cluster: `darkbloom cluster status`)`` (on DevNet,
   `darkbloom-dev cluster status`), or when `Daemon: running` comes with
   ``This is the cluster's part on this Mac, not single-Mac serving (…)``:
   that is the pair's own part. Otherwise, if it shows `Daemon: running` and
   lists warm models, **STOP** and ask the human whether to stop single-Mac
   serving there before the pair starts. On a Mac that isn't paired yet that is
   `darkbloom stop`; on one that is paired already, `darkbloom stop --solo`.

### 5. Two Macs: pair them

`darkbloom cluster` is interactive and needs a terminal. Without one, it
prints ``Run `darkbloom cluster` in a Terminal window on this Mac.`` and exits
with status 1. So the human runs it in Terminal on each Mac and reads the
screen to you, or pastes it. If you have a real interactive terminal on that
Mac, you may run `NO_COLOR=1 darkbloom cluster` there yourself: it then prints
plain lines and numbered choices. Even then, the pairing code and every macOS
prompt are the human's (rules 6 and 7). A first setup opens, on both Macs, with what the
human will be asked on each Mac's own screen (Screen Sharing for a Mac with
no display) and about how long it takes, then has four steps:
**1/4 Connect**, **2/4 Pair**, **3/4 Model** and **4/4 Start**
([details](two-mac-cluster.md#the-steps-once)).

1. On the leader, run `darkbloom cluster`. It shows `1/4 Connect` and `Allow
   macOS permissions.` (over SSH: `Allow macOS permissions here and on this
   Mac's screen (Screen Sharing if headless).`). If the cable port isn't set up yet, macOS
   asks once for the administrator password, and the human types it; a port
   set up before asks nothing. Next come `✓ Cable ready`, `2/4 Pair` and
   ``Run `darkbloom cluster` on the other Mac.``. The leader then waits. If the
   other Mac isn't found within about 30 seconds, the screen lists what to
   check, starting with `The other Mac isn't found yet. Check that:`.
2. On the other Mac, run `darkbloom cluster`. The same password prompt
   appears there. Then both screens show `Code 123 456. Same on the other
   Mac?`. **STOP**: the human compares the two codes and chooses **Yes** on
   each Mac only if they match, or **No** if they don't. Enter selects
   **Yes**, so never press Enter for the human.
3. The screens say ``✓ Paired. This Mac (…) leads.`` and `✓ Paired. The other
   Mac leads.`. Each Mac's cluster service then starts, and it needs macOS's
   Local Network access. The screen may ask for it (for example `Click Allow on
   the Local Network prompt for Darkbloom. Allow it on the other Mac too.`, then
   `✓ Allowed`; on DevNet it names Darkbloom Dev), but don't wait for a macOS
   prompt in this terminal. **STOP** on each Mac: the human, at that Mac's own
   screen (Screen Sharing on a Mac with no display), opens System Settings →
   Privacy & Security → Local Network and turns on “Darkbloom”. The DevNet app
   is listed as “Darkbloom” too: both apps share one bundle ID. If the list has
   no “Darkbloom” row, macOS has never asked on that Mac: it asks on that Mac's
   screen the next time the app dials over the cable (when the pair starts),
   and the human clicks **Allow** there. You can't see or change this setting.
   If it is still off when the pair starts, the leader's ✗ in step 7 says so
   within about 20 seconds ([Local Network](#on-a-two-mac-pair)).
4. The other Mac then says ``Waiting for the other Mac (…) to choose the model
   and start…``. With a leader on this release or later, it also says once what
   the leader's screen waits on, such as ``The other Mac (…): it's waiting for
   Allow on its Local Network prompt.`` or ``… it's waiting for a model to be
   chosen on its screen.``: **STOP** and have the human answer it on the
   leader. Its live line shows how long it has waited out of 15 minutes. It then
   follows the start, one line per change, such as ``The other Mac: <status>.``.
   If it ends with ``✗ Not serving: The two Macs run different Darkbloom
   builds.``, run `darkbloom update` on the Mac it names (or on the one whose
   `darkbloom --version` is lower), then `darkbloom cluster` on the leader. If
   it ends with ``✗ Not serving: The other Mac (…) didn't start a model within
   15 minutes.``, the leader's screen is still waiting on the step it names. When a part ends there, it adds ``Choose Retry
   on the other Mac (…): its screen shows the choices.``. If macOS keeps this
   Mac off the local network, it says ``This Mac can't reach the other Mac
   over the cable: macOS keeps Darkbloom off the local network.`` and where to
   turn it on. It ends with the same ✓ or ✗ block as the leader; after ✓ it
   says `You can close this window.`. Everything after this is chosen on the leader.

If ``Cable port not set up. Run `darkbloom cluster` again.`` appears, the
password prompt was declined or failed. Run `darkbloom cluster` again with
the human at the Mac. If one Mac waits at `2/4 Pair` while the other shows
its status, or says that the other Mac isn't answering over the cable, that
Mac still holds an old pairing. See [troubleshooting](#troubleshooting).

### 6. Two Macs: choose the model (on the leader)

`3/4 Model` reads both Macs and plans each model (a colour screen says
`Reading both Macs over the cable` and `Planning each model for both Macs`
meanwhile; with `NO_COLOR=1` these working lines don't print), then shows a
list. The list has only the models approved for clusters (GLM-5.3-Flash,
Qwen3.8 27B, MiMo-V2.6-Flash and Gemma 4 26B QAT) that these two Macs can
serve. Each line gives the name, the size and the mode or modes, the one
recommended for these Macs first. No line shows a speed:

```text
  1) gemma-4-26b-qat-4bit · 15.6 GB · tensor parallel or pipeline
  2) Qwen 3.8 27B · 16.3 GB · tensor parallel
  3) Z.ai: GLM-5.3-Flash · 181.8 GB · download · not enough free disk
```

A line ends with `copy` or `download` when one Mac lacks the model. Lines that
end with `does not fit now` (apps hold the memory it needs) or
`not enough free disk` come after the others.

Tell the human how the split works. Never choose a model for them; for the
mode, take the one the screen recommends (step 2):

- **Tensor parallel** splits every layer across both Macs. Each Mac holds
  half of every layer, and both work on every token.
- **Pipeline** gives each Mac a share of the layers. A request passes through
  one Mac's layers, then the other's.
- The planner picks, for each model, the fastest measured mode that keeps
  every feature. Qwen and GLM use tensor parallel wherever it fits. Gemma 4
  and MiMo stay on pipeline until tensor parallel has been measured faster on
  both Macs.
- Mixed pairs, such as M3 Ultra + M5 Max, are supported. The chip doesn't
  decide anything. Each Mac's free memory decides what it holds, and a pair
  served through Darkbloom gets equal shares
  ([how the split is chosen](two-mac-cluster.md#how-the-split-is-chosen)).

1. **STOP**: read the list to the human and ask which model to serve. Enter
   selects the first line. Rule 5 applies: a `download` model is downloaded on
   the leader and then copied, so it takes its full size on each Mac.
2. If the screen then asks ``How should both Macs split <model>?``, its first
   line is ``Recommended for <model> on these two Macs: <mode>, <why>.`` (the
   why is shorter, or left out, in a narrow window) and that mode's line
   ends with `· recommended for these Macs`; Enter selects it. Pick the
   recommended mode unless the human wants the other: it is the one that fits,
   serves the longest context (each mode's line says its context), serves more
   requests at once through Darkbloom, or is faster on these Macs.
   When the line is ``No recommendation for <model> on these two Macs: <why>.``, read the why
   to the human and keep the selected line unless they choose otherwise.
3. If the model still has to reach a Mac, a second list offers `Download`,
   `Copy to the other Mac (about N s)` or `Copy from the other Mac`, and
   `Cancel`. Enter selects the first. Progress is shown, and an interrupted
   copy resumes.
4. ``Can't start <model>: <reason>. Free space, then run `darkbloom cluster`
   again.`` means a Mac doesn't have the model's size free now, plus 2.1 GB.
   **STOP**: tell the human the reason. Nothing was downloaded or copied.

### 7. Two Macs: start, and read the result

`4/4 Start` runs on the leader:

1. Login check. Before anything starts, the leader names each Mac without a
   Darkbloom login, for example ``This Mac and the other Mac (…) aren't logged
   in to Darkbloom, so the coordinator won't pair them.``. It offers **Log in
   on this Mac**, **Serve locally only** (**Only me**) and **Cancel**. **Log in on this Mac**
   runs `darkbloom login` in this terminal, as in step 2. When only the other
   Mac lacks a login, the first choice is **Check again** instead: run
   `darkbloom login` on the other Mac, then choose it. Choose **Serve locally
   only** only if the human wants no Darkbloom traffic.
2. `Loading takes a few minutes for a large model; both Macs show progress
   here.` On a colour terminal a live line shows the wait and the time so far,
   for example `Loading Qwen 3.8 27B on both Macs · 0 s…`, with the parts'
   state in brackets when one starts again. A pair offered to Darkbloom then
   shows a row per Mac while Darkbloom pairs them. The leader waits at most
   15 minutes for both Macs to load the model and answer a first request.
   Wait, and don't touch either Mac.
3. The result appears as one block. Success is the `✓` block, then the
   pair's card: `Model:`, `Macs:`, `Serves:` (or `Local:` for a pair serving
   **Only me**), `Logs:`, a line about starting at login (such as
   `Starts by itself at login on both Macs.`), a line about restarts, and the
   commands `darkbloom stop`, `restart` and `status`. The command then returns
   to the shell. Whatever the login line says, [verify](#two-macs) checks it on
   each Mac. A failure looks like this, followed by the choices **Retry**,
   **Change model**, **Serve locally only** and **Diagnostics**:

   ```text
   ────────────────────────────────────────────────
   ✗ Not serving: <reason>.
     <what to do>
   ────────────────────────────────────────────────
   ```

   Act on the reason ([troubleshooting](#troubleshooting)), then choose
   **Retry**. Pressing q leaves with ``Not serving yet. Both Macs keep trying by
   themselves; run `darkbloom cluster` to check.`` and exit status 1.

   On a stopped pair, **Retry** starts both Macs again (`The pair is stopped:
   starting both Macs again.`). While the start waits, q, Esc or Ctrl-C leaves
   with ``Left the start: the pair keeps starting by itself; run `darkbloom
   cluster` again to see how it is going.`` and exit status 1. A Mac that macOS
   keeps off the local network ends the wait within about 20 seconds with its
   own ✗ ([Local Network](#on-a-two-mac-pair)).
4. Go to [verify](#two-macs).

## Verify it really serves

Never report success because a start command finished.
``Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to accept
this pair…`` on the screen, or `Registered with the coordinator as a cluster
member` in a log, does not mean serving: the coordinator still has to pair
both Macs, and both have to load the model.
Before 0.10.8, the setup could even say `✓ Serving … Done.` with nothing loaded.

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

With **Both** (the default) or **Only me**, the Mac also has a local API.
`darkbloom local --json | jq -r .base_url` prints its address alone; plain
`darkbloom local` prints the key too (rule 6).

In the first minutes after a start, `Traffic: not yet eligible (…)` is
normal. Check again every few minutes without restarting anything (rule 8).
If it is still there after 15 minutes, read doctor's `APP ATTEST` lines
([troubleshooting](#troubleshooting)). `Traffic: NOT receiving coordinator
work: …` comes with a `→ fix:` line: follow it. Then send a
[test request](#a-test-request-through-darkbloom).

### Two Macs

Check all three:

1. The result block of the setup (or of `darkbloom start`) starts with `✓`.
2. On each Mac, run:

   ```bash
   darkbloom cluster status --json; echo "exit status $?"
   ```

   It only reads. On the Mac that follows, it asks the leader over the cable:
   after 3 seconds it says `Waiting for the leading Mac's answer (up to 10 s).`,
   and at 10 seconds `The leading Mac didn't answer in 10 s; this is this Mac's
   own view.`, with `other_mac.answers` then `null` (with `--json`, these lines
   go to standard error).
   The pair serves when the exit status is `0` and `state` is `serving`: both
   Macs loaded the model and the pair answered its first request. Otherwise
   act on `state`, `reason` and `next`:

   | Exit status | `state` | Do |
   |---|---|---|
   | `0` | `serving` | Go on |
   | `3` | `not_serving` with `reason` ``This Mac can't reach the other Mac over the cable: macOS keeps Darkbloom off the local network`` or ``The other Mac can't reach this Mac over the cable: macOS keeps Darkbloom there off the local network`` (on DevNet, both name Darkbloom Dev) | macOS keeps that Mac off the local network, and nothing changes until someone turns it on. Don't wait. **STOP**: ask the human to do this on the Mac `next` names: System Settings → Privacy & Security → Local Network → turn on “Darkbloom” (the DevNet app is listed under that name too); if it isn't listed, click **Allow** when macOS asks on that Mac's screen, the next time the app dials over the cable; through Screen Sharing on a Mac with no display. Then run `darkbloom start` (on either Mac), or choose **Retry** in `darkbloom cluster` on the leader ([Local Network](#on-a-two-mac-pair)) |
   | `3` | `not_serving` with `reason` ``not offered to Darkbloom (…)`` | The pair serves on the leading Mac's local API only: the coordinator doesn't have it, and it earns nothing. The parenthesis says why. Don't restart anything. **STOP**: ask the human to run `darkbloom cluster` on the leader and choose the model again, which plans it for Darkbloom and asks the coordinator (`next` says the same) |
   | `3` | `not_serving` with another `reason` | Follow `next` and [troubleshooting](#troubleshooting) |
   | `3` | `loading`, `unknown` | Check again every few minutes, for up to 15 minutes, without restarting anything (rule 8). If it still says so after 15 minutes, **STOP**: the human runs `darkbloom cluster` on the leader, which shows more |
   | `4` | `stopped` | The pair is stopped. If the other Mac isn't answering too, the lines add ``The other Mac (…) isn't answering over the cable.``. During a model or mode change, or while the pair updates Darkbloom, `status` and `cluster status` can read `stopped` (exit 4) or `unknown` for a minute or two while the pair is actually reloading. If such a change happened recently, or the status showed "Updating…", wait about a minute and check again before you act. Only if it still reads `stopped`: **STOP**, ask the human, then run `darkbloom start` |
   | `5` | `other_mac_away` | The other Mac isn't answering over the cable. **STOP**: `next` says why and what to run on that Mac, and, once this Mac's part was given up, that `darkbloom start --solo` serves this Mac alone (only with the human's go) |
   | `6` | `not_paired` | This Mac isn't in a pair. Go back to [step 5](#5-two-macs-pair-them) |
   | `7` | `pairing_unreadable` | This Mac's pairing record couldn't be read. **STOP**: the human runs `darkbloom cluster` on this Mac to check it |

   On each Mac, `service.running` and `service.starts_at_login` should also be
   `true`. If `service.starts_at_login` is `false` on a Mac, its part won't
   start by itself at login: **STOP**, tell the human, and ask them to run
   `darkbloom cluster` on that Mac, then check again.

   The other keys are `schema` (`1`), `paired`, `role` (`leader` or
   `member`), `this_mac`, `other_mac` (`name`, `answers`), `model` (`id`,
   `name`), `mode`, `split`, `serves` (`darkbloom` or `local`), `lines` and
   `exit_code`. Every key is present, `null` when unknown
   ([CLI reference](cli-reference.md#darkbloom-cluster-status)). Without
   `--json`, the command prints the same in plain lines for the human.
3. A [test request](#a-test-request-through-darkbloom) answers.

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

One failed request does not mean the pair stopped. From 0.10.8, a request
that runs out of time before it starts fails alone, and the pair keeps
serving. Check `darkbloom cluster status` before you act on it.

The test proves that the pair serves only if no other Mac of the account
serves the same model. See [self-route](self-route.md) for more. A pair that
serves **Only me** takes no requests through Darkbloom. Its API is on the
Mac that `darkbloom cluster status` names, and `darkbloom local` there prints
the API key. Its start already answered a test request; to send one again,
the human chooses the model it serves in
[the pair's model list](#the-pairs-model-list).

## Manage it later

On a pair, each of these works from either Mac unless the table says
otherwise ([stopping and starting again](two-mac-cluster.md#stopping-and-starting-again)):

| To | On | Do |
|---|---|---|
| See whether the pair serves, and why not | Either Mac | `darkbloom cluster status` (`--json` for you). `darkbloom status` starts with the same block |
| Stop the pair | Either Mac | `darkbloom stop`, the same as `darkbloom cluster stop`. Both Macs stop and stay stopped after a restart. If it takes a while, it says `Waiting for both Macs to stop; accepted requests finish first (up to about 6 min).` and `Waiting for both Macs' parts to end (up to 1 min).`. Once both parts have ended it says `Stopped on both Macs.` and `Memory freed on both Macs ✓` (exit status 0). `Asked both Macs to stop; …` with what still runs means a part hasn't ended yet (exit status 1): run `darkbloom stop` again a minute later |
| Start it again | Either Mac | `darkbloom start`. Without a terminal it starts the saved model on both Macs; if it has to wait, it says `Waiting until the pair serves (up to 10 min).`, repeating an unchanged status each minute (`Still waiting (up to 10 min in all): …`). It waits through reasons the Macs fix by themselves, then prints a result block. Exit status `0` means it serves, `3` not yet, `4` stopped, `5` the other Mac isn't answering, `1` it couldn't start. If this Mac's cluster service runs from a terminal session, it first says ``This Mac's cluster service runs from a terminal session: replacing it with its login agent, which starts at login (this Mac's part restarts).``. If macOS keeps this Mac off the local network, it ends at once with where to turn it on and ``…; then run `darkbloom start` again.``, exit status 1. In a terminal it opens the `darkbloom cluster` screen |
| Restart it with the same model | Either Mac | `darkbloom restart`, with the same result block and exit statuses. If it takes a while, it says the same waiting lines (the parts' wait is up to 5 min). If a part hasn't released its memory after the stop, it doesn't start again and exits with status 1 |
| Change or test the model, or how the pair serves | The leader, in a terminal | `darkbloom cluster`, or `darkbloom start` in a terminal ([below](#the-pairs-model-list)) |
| Start over and pair again | Either Mac, in a terminal | `darkbloom cluster` → **Start over (unpair and set up again)** → **Yes, start over**. Then run `darkbloom cluster` on the other Mac and choose **Start over (unpair and set up again)**, or **Pair again**, if it offers it ([pairing again](two-mac-cluster.md#pairing-again)) |
| Update | Every Mac | `darkbloom update` on each Mac, and the pair restarts together. Automatic updates are on by default |
| Serve on one Mac alone instead of the pair | That Mac | While the pair runs: stop it first (`darkbloom stop`), then `darkbloom start --solo --model <id>`. While it doesn't run here (the other Mac is gone or stopped clustering): `darkbloom start --solo --model <id>` serves this Mac alone. Plain `darkbloom start` starts the pair in every state, and single-Mac options without `--solo` are refused by name (exit 64). `--solo` is refused only while the pair runs here. `stop --solo`, `restart --solo` and `status --solo` act on single-Mac serving alone. Stop it with `darkbloom stop --solo` before you start the pair again |
| Stop one Mac whose partner is gone for good | That Mac | `darkbloom cluster stop --local-only` |
| Keep this Mac's cluster service from starting at login | That Mac | `darkbloom cluster stop --service`. It stops the pair first. `darkbloom cluster` turns it on again |
| List the cluster commands | Any Mac | `darkbloom cluster --help` |

`darkbloom start` without a terminal needs a model chosen earlier. Otherwise
it says ``No model was chosen for the pair yet: choose one with `darkbloom
cluster` in a terminal on this Mac.`` (on the Mac that follows: ``… on the
other Mac (…).``, which leads) and exits with status 1. Other single-Mac options
are refused there by name, without `--solo` (exit status 64); `--model <id>`
(and `--local-endpoint`), the desktop app's Start, start the pair with its own
model and end with ``This Mac serves in a pair: the pair serves <model>;
`darkbloom cluster` changes its model.`` when that isn't `<id>` (after exit
status 3: ``This Mac is in a pair: the pair was asked to start with <model>, and
isn't serving (above); …``).
Without a terminal, a stopped pair's start looks like this. `checking both
Macs with Apple` is the usual first minute of each part, not a failure: wait
through it. On a pair that already serves, the first line is ``…: the pair
already serves.``, the result block follows at once, and nothing is asked of
either Mac.

```text
This Mac is in a two-Mac cluster with the other Mac (Apple M5 Max, 128 GB): starting the pair.
  Qwen 3.8 27B: registering both Macs with the coordinator for pairing.
  Waiting until the pair serves (up to 10 min).
  Qwen 3.8 27B is not serving yet: checking both Macs with Apple.
  Qwen 3.8 27B is not serving yet: the coordinator paired both Macs.
✓ Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel).
  Model:   Qwen 3.8 27B · tensor parallel · M3 Ultra 50% / M5 Max 50%
  Macs:    this Mac (Mac Studio) leads · the other Mac (Apple M5 Max, 128 GB) follows
  Serves:  through Darkbloom

  darkbloom stop     Stop both Macs
  darkbloom restart  Restart with the current model
  darkbloom status   Check status
```

### The pair's model list

On the leader, `darkbloom cluster` opens with both Macs and the cable, then
the pair's ✓ or ✗ status, then the pair's model list. The model serving now
(or the one last used) is selected:

- Enter on the model serving now (and on its mode, if asked) sends one test
  request: ``✓ Already serving <model>; test response in N s`` and the card,
  or the ✗ block with its choices. A pair served only through Darkbloom has no
  local API on that Mac to test from, and the screen says so: use the
  [test request](#a-test-request-through-darkbloom) instead.
- On a stopped pair, Enter starts the last model again.
- Another model asks ``Switch to <model>? …`` once (**No** by default), then
  says `✓ Stopped <model> on both Macs`, shows each Mac's load and ends like a start.
- A line that ends with ` · not enough free disk` is refused before anything stops.
- **Change how the pair serves** (**Only me**, **Darkbloom network** or
  **Both, me first**) and **Start over (unpair and set up again)** are lines in
  the same list. q changes nothing.

On the Mac that follows, `darkbloom cluster` shows the pair's status,
`This Mac runs its part by itself.` and ``To change the model, run `darkbloom
cluster` or `darkbloom start` on the other Mac (…). `darkbloom stop` here
stops both Macs.``. Enter closes; **Start over (unpair and set up again)** is
the other choice.

## Uninstall

`darkbloom uninstall` takes Darkbloom off one Mac in one of two ways
([every step and path](cli-reference.md#darkbloom-uninstall)):

| Choice | Flag | Removes | Keeps |
|---|---|---|---|
| Remove everything | `--everything` | The app, settings, pairing, logs and every model Darkbloom downloaded | Models in folders the human chose (an external drive, for example) and Keychain keys |
| Keep models | `--keep-models` | Everything else, including settings and the pairing, so a reinstall starts clean | The models Darkbloom downloaded and the cluster's copies of them, which a reinstall finds without downloading, plus all that **Remove everything** keeps |

Both choices stop serving the way `darkbloom stop` does, stop this Mac's part
of a pair, remove Darkbloom's background services, revoke this Mac's account
token, unpair the Mac, undo the cable port setup (macOS asks for an
administrator password) and remove the `darkbloom` command link. The summary
lists each step as done, skipped or failed, and the space freed. The exit
status is 1 when a step failed or a folder was not removed (its line says
`not removed: <why>`). Without a terminal, the command needs a choice and
`--yes`; otherwise it prints its `Usage:` line and exits with status 64. Run
it as the logged-in user, never with `sudo`: it refuses `sudo` (exit status
64) and asks for the password itself when a step needs it. In a terminal
without flags, **Remove everything** asks once more before it starts.

With both the production and the DevNet app on a Mac, uninstalling one
(`darkbloom uninstall` or `darkbloom-dev uninstall`) removes only that app's
own pairing, cluster setup and cluster service, as on a Mac with one app, and
leaves the other app's pair and cluster service as they are. It keeps the cable
port setup and the shared models for the other app, so it asks for no password
([details](cli-reference.md#darkbloom-uninstall)).

1. **STOP**: ask the human which choice they want, and show them the plan
   first. `--dry-run` changes nothing and needs no `--yes`. Add `--json` for
   the plan as JSON:

   ```bash
   darkbloom uninstall --everything --dry-run    # or --keep-models --dry-run
   ```

2. With the human's go:

   ```bash
   darkbloom uninstall --everything --yes        # or --keep-models --yes
   ```

   `failed   Undo the cable port setup: …` means the macOS prompt was
   declined or could not show (over SSH). `~/.darkbloom` stays for this. The
   human runs the same command again at the Mac's screen.

3. On a paired Mac, the last line is about the other Mac: run `darkbloom
   uninstall` there too, or run `darkbloom cluster` there to pair it with
   another Mac.

## Troubleshooting

### On any Mac

| Signal | Cause | Do |
|---|---|---|
| The console says the Mac is waiting for verification, or `✗ Not serving: <Mac> isn't verified by Apple yet; Darkbloom retries by itself at about HH:MM. Don't restart either Mac until then.` | Apple's App Attest has not verified that Mac yet. The coordinator sends work only to verified Macs, and pairs only those. On a pair the ✗ comes only once a Mac's part has run 2 minutes without it, or its key-generation safeguard holds it back; before that, `… is not serving yet: checking both Macs with Apple.` is the usual first minute (`loading`, nothing to do) | Run `darkbloom doctor` on that Mac. If `app attest key — no usable key; the local key-generation safeguard clears in <time>` appears, wait that long. Don't restart, stop or start anything, and don't delete Keychain items. Leave the Macs alone: Darkbloom retries by itself. Check every few minutes with `darkbloom status` (one Mac) or `darkbloom cluster status` (a pair). From 0.10.8, a stop, an update or a lost connection during Apple's call keeps the attestation, but a crash or a forced kill still blocks a new key for up to an hour |
| doctor: ``[FAIL] app attest support — Apple reports App Attest as unsupported for this provider process (`is_supported_false`), although it already runs in the logged-in GUI session …``, usually right after an update | macOS still describes the app that the update replaced. 0.10.8 refreshes that record after an update, and again when Apple first says unsupported | Wait up to 10 minutes, then run `darkbloom doctor` again. If the line stays, tell the human, then run the `lsregister -f` command that doctor prints under `↳ fix:`. It changes no Darkbloom file or key. Then wait for the next check (up to 10 minutes) instead of restarting (rule 8) |
| `Traffic: NOT receiving coordinator work: …` with `→ fix: …` | The coordinator doesn't route work to this Mac | Do what the fix line says |
| Anything else, or no progress | — | [Report it](#report-a-problem) |

### On a two-Mac pair

The reasons and their fixes are also in [a two-Mac cluster says "Not serving
yet"](troubleshooting.md#a-two-mac-cluster-says-not-serving-yet) and
[two-Mac pairs](troubleshooting.md#two-mac-pairs).

| Signal | Cause | Do |
|---|---|---|
| The human stopped clustering, and the Mac is online but gets no requests; `darkbloom status` says ``The other Mac (…) hasn't answered for 15 min; this Mac's part stopped.`` or ``The pair hasn't served for … min``; on 0.10.8 `darkbloom start --solo` says ``This Mac's part of the pair holds its serving lock`` | The Mac kept the pair's saved start, so its cluster service ran its part of a pair that no longer forms. That part registers only as a pair member, which gets no ordinary requests | With the human's go, run `darkbloom start --solo --model <id>` on that Mac (0.10.9 or later): it stops the leftover part and serves this Mac alone. Plain `darkbloom start` starts the pair instead. On 0.10.8: `darkbloom cluster pair --status`, then `darkbloom cluster pair --forget <pin>`, then `darkbloom start`. Never plain `darkbloom stop` on 0.10.8 for this: it acts on the pair |
| ``✗ The pair can't start: a single-Mac Darkbloom provider (process <N>) is serving on <Mac>, …``; a cluster status or log line ``a single-Mac Darkbloom provider (process <N>) is serving on this Mac, so this Mac's part can't start``; an incident `local_provider_running`. In 0.10.8 the same cause read ``another update operation owns the lock (pid <N>, provider-instance)`` and looped ``this Mac's part ended … and starts again by itself`` | Single-Mac serving runs on that Mac and holds its one serving lock, so the pair's part can't start there. It doesn't end by itself | **STOP**: ask the human whether to stop single-Mac serving on each Mac named. With their go, run `darkbloom stop --solo` on that Mac, then `darkbloom start` (on DevNet, `darkbloom-dev`). In `darkbloom cluster`, **Stop single-Mac serving on both Macs and start the pair** does both. Both Macs' `darkbloom cluster status` say the block, with `next` ``Single-Mac serving doesn't stop by itself: …`` (`state` `not_serving`, exit status 3), and the joining Mac's window shows the same ✗. Neither Mac keeps restarting its part meanwhile; don't wait for it to clear by itself. From 0.10.9, single-Mac serving that nobody chose since the pair was started steps aside by itself (`darkbloom status` says ``Single-Mac serving stepped aside for the pair …``). Only a choice the human made (`start --solo`) keeps it. `darkbloom stop --solo` on the other Mac finds it there and asks (`--yes` for scripts). Never plain `darkbloom stop` for this: on a paired Mac it stops the pair and leaves single-Mac serving running |
| The leader's ✗ says ``The other Mac can't reach this Mac over the cable: macOS keeps Darkbloom there off the local network.``, then ``The other Mac (…): System Settings → Privacy & Security → Local Network → turn on “Darkbloom”; if it isn't listed, click Allow when macOS asks on that Mac's screen, the next time Darkbloom dials over the cable (on a Mac with no display, through Screen Sharing). Then choose Retry here.``. On that other Mac: ``This Mac can't reach the other Mac over the cable: macOS keeps Darkbloom off the local network.`` (on DevNet, both name Darkbloom Dev, and add that macOS lists Darkbloom Dev as “Darkbloom”). `darkbloom cluster status` shows the same reason as ``✗ Not serving: <reason>.``, then ``Next: …`` (`--json`: `state` `not_serving`, exit status 3), on that Mac at once, and on the leading Mac from about 20 seconds into its part, steadily after that while that Mac stays refused | macOS keeps that Mac's cluster service off the local network, so its link to the other Mac is refused | **STOP**: the human, at that Mac's screen (Screen Sharing if it has no display), opens System Settings → Privacy & Security → Local Network and turns on “Darkbloom” (the DevNet app is listed under that name too), or, with no such row, clicks **Allow** when macOS asks on that screen. Then choose **Retry** where the ✗ offers it (usually on the leader), or run `darkbloom start` on either Mac, as `next` says. Until then, `darkbloom start` on the Mac that is kept off ends at once with the same lines and exit status 1 |
| doctor: ``[FAIL] cluster savedConfiguration: <file> saves this Mac's cluster setup, but other users can open it (mode 644); run `chmod 600 <file>` …`` | The saved setup is in a file other users can open | **STOP**: tell the human, and run that `chmod 600` command only with their go ([step 2](#2-log-in-and-check-the-mac-every-mac)) |
| After installing another build of the same app on a paired Mac (the signed release over a local build, or the reverse), `darkbloom cluster` shows the old pairing as usual, or says the other Mac isn't answering, and offers no **Pair again** | The builds share the app's pairing, and the new build may not notice that its key differs | With the human's go, choose **Start over (unpair and set up again)** → **Yes, start over** on both Macs, then pair as in step 5 |
| After updating the DevNet app from a build that shared the production app's pairing, `darkbloom-dev cluster` shows the Mac as not paired | The DevNet app keeps its own pairing in `~/.darkbloom-dev` and no longer reads production's | Update the DevNet app on both Macs, then pair it again as in step 5. The production app's pairing is unchanged |
| doctor: `[FAIL] cluster localLinkIsolation.rdma_enN: clusterSubnetInUse: The cluster port enN cannot be isolated yet (the cluster subnet 10.219/16 is already used on this Mac) …`, on a version below 0.10.8 | A known false alarm on paired Macs: macOS reaches the port's own address through a loopback route | Don't stop for it, and never run `darkbloom cluster link --remove` because of it. Verify serving instead, and update both Macs. 0.10.8 no longer reports it |
| The same `[FAIL]` on 0.10.8 or later | Another interface or a VPN on this Mac uses 10.219/16 | **STOP**: show the human the line. They remove that address or VPN route, then run `darkbloom cluster` again |
| `This Mac's Secure Enclave key changed after it paired …`, or one Mac waits at `2/4 Pair` while the other shows its status | An old pairing: a Mac was reinstalled, unpaired or replaced, or moved between apps | On the Mac with the old pairing, choose **Pair again** if it offers it, otherwise **Start over (unpair and set up again)** → **Yes, start over**. Then pair as in step 5 ([pairing again](two-mac-cluster.md#pairing-again)) |
| `The other Mac (…) isn't answering over the cable. …`, or `darkbloom cluster status` exits with status 5 | That Mac's cluster service is off, or the Mac is asleep, off, or waiting for someone to log in | **STOP**: the human wakes or logs in to that Mac and runs `darkbloom start` or `darkbloom cluster` there. Then choose **Try again** here, or run `darkbloom cluster status` again. Silence is not a broken pairing: use **Start over (unpair and set up again)** only if that Mac was reinstalled, unpaired or replaced |
| `<model> doesn't fit in free memory now: Quit apps on … first.`, a list line ending `does not fit now`, or `✗ Not serving: <Mac> lacks free memory for its share` | That Mac's apps hold memory its share needs | **STOP**: ask the human to quit apps (or stop single-Mac serving there with `darkbloom stop --solo`), then **Retry**. Or choose a smaller model. Never raise `iogpu.wired_limit_mb` or change other memory settings to force a fit |
| ``Can't start <model>: … Free space, then run `darkbloom cluster` again.``, or a list line ending `not enough free disk` | A Mac doesn't have the model's size free now, plus 2.1 GB | **STOP**: tell the human the figures in the line. They free space on that Mac (`tmutil listlocalsnapshots /` lists local snapshots), then run `darkbloom cluster` again |
| `No approved model can run on these Macs now.` | No approved model fits these Macs or is supported on them | Read the reasons it prints, then **STOP** |
| `… aren't logged in to Darkbloom …` or `[WARN] account link: not logged in` | No Darkbloom login on that Mac | Run `darkbloom login` on that Mac (step 2), then **Check again** or **Retry** |
| `A part keeps ending the same way: …` | One Mac's part keeps failing at start | Choose **Diagnostics**, which saves a redacted file in the home folder. Then [report it](#report-a-problem) |
| `darkbloom stop` says `Asked both Macs to stop; …`, then what still runs (exit status 1) | Both Macs took the stop, but a part hasn't ended yet | Wait a minute, then run `darkbloom stop` again: once both parts have ended it says `Stopped on both Macs.` and `Memory freed on both Macs ✓`. Don't kill Darkbloom processes |
| ``… `--autopilot` is for single-Mac serving, so nothing was started.`` (any single-Mac option; exit status 64), or ``This Mac's part of the pair holds its serving lock, so single-Mac serving can't start beside it. …`` | On a paired Mac, single-Mac options need `--solo`, and `--solo` needs the pair stopped | Leave the pair alone. Only if the human wants this Mac to serve alone: `darkbloom stop`, then `darkbloom start --solo --model <id>` |
| `This Mac isn't in a cluster, but a cluster service is still set up on it (left from an earlier pairing).` (exit status 6) | A cluster service without a pairing, left from an earlier pairing | To pair, go to step 5. To remove it, with the human's go: `darkbloom cluster stop --service` |
| `darkbloom stop` on the Mac that follows says `Nothing was stopped on this Mac.` | The leader stops both Macs, and it isn't answering | Wake or log in to the leader, then run `darkbloom stop` again. Only if the human says the leader is gone for good: `darkbloom cluster stop --local-only` |
| `This Mac's pairing record couldn't be read (…), so it may be in a two-Mac cluster.` | The pairing file is damaged or unsafe | **STOP**: the human runs `darkbloom cluster` on this Mac to check it. Don't add `--solo` to get around it |
| ``Run `darkbloom cluster` in a Terminal window on this Mac.`` | It ran without a terminal | Ask the human to run it in Terminal (step 5) |
| `cluster update: v… is installed, but the update record said … (installed outside the updater) …` in a cluster log | This Mac was reinstalled with the installer, and 0.10.8 corrected its update record | Nothing to do. No older release is kept to roll back to until the next update |

### Report a problem

**STOP** and ask before you upload anything. `darkbloom report` uploads this
Mac's recent Darkbloom logs and App Attest evidence to Darkbloom, and
`darkbloom report --dry-run` prints what it would send. A successful upload
ends with `Report ID: <n>`: give that number to the human. macOS lets only
administrator accounts read the system log, so on a standard account the
human may run `sudo darkbloom report`.

### Older builds

This section is for production builds below 0.10.8; a DevNet build's number
doesn't place it here ([DevNet](#devnet-testers-only)). Update every Mac first
with `darkbloom update`. If no newer release is offered yet:

- The setup can say `✓ Serving … Done.` with nothing loaded. Always verify
  with a [test request](#a-test-request-through-darkbloom).
- `darkbloom cluster status` prints a report for support, with no `--json`
  and no exit statuses.
- On a paired Mac, `darkbloom start`, `stop`, `restart` and `status` act on
  single-Mac serving only, and `darkbloom stop` can stop the pair's own part.
  Manage the pair only with `darkbloom cluster` and `darkbloom cluster stop`.
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
| `app attest key`, `app attest support` and the key-generation safeguard | `provider-swift/Sources/ProviderCore/Diagnostics/AppAttestLocalDiagnosis.swift` |
| `Traffic:` lines | `provider-swift/Sources/darkbloom/StatusCommand+Traffic.swift` |
| `Local link:` states and the `localLinkIsolation` check | `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkReadinessState.swift`, `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkIsolationStatus.swift` |
| Models approved for clusters, and the tensor-parallel and pipeline placements | `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift` (`declared`, `placement`) |
| Tensor parallel first wherever it fits | `provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementFlow.swift` (`tensorParallelFirst`) |
| The setup's steps, code question, lists, login check, result block and card, and the test on the serving model | `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterOnboardingFlow.swift` (`ClusterOnboardingDriver.checkLogins`, `finishStart`, `pairCard`, `testServing`) |
| The joining Mac following the first start | `ClusterOnboardingDriver.followStart` |
| Why a pair does not serve | `ClusterOnboardingNotServing` |
| `darkbloom start`, `stop`, `restart` and `status` on a paired Mac | `provider-swift/Sources/darkbloom/Start/StartCommand.swift` (`Start.pairStart`), `provider-swift/Sources/darkbloom/StopCommand.swift` (`Stop.pairedStop`), `provider-swift/Sources/darkbloom/RestartCommand.swift` (`Restart.pairRestart`), `ClusterPairCommands` |
| `darkbloom cluster status`, its exit statuses and `--json` | `provider-swift/Sources/darkbloom/ClusterDiagnosticsCommand.swift` (`Cluster.Status`), `ClusterPairSummary.JSON` |
| `darkbloom cluster stop` and the `link --remove` question | `provider-swift/Sources/darkbloom/ClusterServiceCommand.swift` (`Cluster.Stop.mode`), `provider-swift/Sources/darkbloom/ClusterLinkCommand.swift` (`Cluster.Link.removalGate`) |
| `darkbloom uninstall` | `Uninstall`, `ProviderUninstall.invocation` |
| Local Network: the step, the follower's refusal and the lines that name it, also in `darkbloom cluster status` | `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterLocalNetworkAccess.swift` (`ClusterLocalNetworkAccess.serviceState`, `statusWords`), `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterService.swift` (`ClusterService.followerRefusal`), `provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterOnboardingLive.swift` (`localNetworkRefusalLines`), `ClusterOnboardingDriver.localNetworkBlockedLines`, `provider-swift/Sources/darkbloom/ClusterLinkFollowerCommand.swift` |
| doctor's cluster checks and the saved setup's file mode | `provider-swift/Sources/darkbloom/DoctorClusterChecks.swift`, `provider-swift/Sources/ProviderCore/Config/ClusterConfigurationInstalledReference.swift` (`notPrivate`) |
| The pair's local API port | `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterLocalServing.swift` (`sharedPort`, `servingPorts`) |
| DevNet names (`darkbloom-dev`, `Darkbloom Dev.app`, `~/.darkbloom-dev`, single-Mac port `8001`) | `provider-swift/identity/provider-identity.json` |
