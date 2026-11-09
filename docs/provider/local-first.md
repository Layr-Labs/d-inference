# Use your Mac yourself, first

> Last updated: 2026-11-08

How your Mac serves is one choice: **Only me**, **Darkbloom network** or
**Both, me first**. This page says what each one runs, costs and earns, how to
choose and switch, and how your tools (OpenCode, Hermes, any OpenAI client)
use your Mac's models.

| Choice | What runs | Where your requests go | Costs and earnings | What stops it |
|---|---|---|---|---|
| **Only me** | Your models, on this Mac's local API (`http://127.0.0.1:<port>/v1`), in the background | To this Mac. Darkbloom never contacts it | Free. Earns nothing; needs no account | `darkbloom stop` |
| **Darkbloom network** | Darkbloom's requests, in the background. No local API | Nowhere here: your tools have no address on this Mac | Earns while it serves; needs your account (`darkbloom login`) | `darkbloom stop` |
| **Both, me first** | Darkbloom's requests, and a local API for you on `http://127.0.0.1:<port>/v1`, in the background | To this Mac first: Darkbloom pauses while you use it and comes back after 2 idle minutes | Yours are free; Darkbloom's earn while you aren't using the Mac | `darkbloom stop` |

In the background means it starts at login, starts again after a crash and
updates itself; closing the Terminal window changes nothing. Like the others,
**Only me** reports itself alive from the start, while it loads its models, so
a long first load (after an update, say) is never taken for a failed start, and
`darkbloom status` says it is starting. Every choice keeps the Mac awake while
it serves (the display can still sleep). Starting **Only
me** where Darkbloom served says so: ``Darkbloom network serving stops: this Mac
serves only you from now on (`darkbloom start --me-first` serves Darkbloom and
you).`` With an account key saved, a request this Mac can't take can go on to
your other Macs, free, or to the network, billed, if you choose
([below](#when-this-mac-cant-take-your-request)).

## Choose once

The first time you run `darkbloom start` in a terminal, it asks:

```text
How should this Mac serve?
  1. Only me, on this Mac      Darkbloom never contacts this Mac. Your tools use this Mac's own API.
  2. Darkbloom network         This Mac serves Darkbloom and earns while it runs.
  3. Both, me first            This Mac serves Darkbloom while you aren't using it. When you use it,
                               Darkbloom traffic pauses until you've been idle for 2 minutes.
Choose 1, 2 or 3 [3]:
```

Press Enter for **Both, me first**, or type 1, 2 or 3. Then:

- **Every choice asks which models to serve** (the list downloads the ones you
  pick) and what to do with memory when idle, then serves in the background.
  When Darkbloom's catalog can't be reached, **Only me** serves the models
  already on this Mac.
- **A Mac with no model it can serve** says what to do:
  ``No model to serve yet. See them: `darkbloom models catalog`. Get one:
  `darkbloom models download <id>`, then `darkbloom start`.``
- **Your answer is saved** in the `[local]` section of `provider.toml`, and later
  starts don't ask again.
- **Nothing is saved until the start goes ahead.** If you cancel the model
  picker, or press Ctrl-D at the question, nothing changes.

## Switch

```bash
darkbloom start --choose
```

It asks the question again, in a terminal, and goes on as a first start does:
the model list and the memory question again. It saves the new answer.

<!-- pending LS-2: a one-step switch that saves the choice and keeps the models, the address and the key, so the tools keep working. -->

## No terminal, no question

Starts without a terminal never ask:

- **At login, and after a crash or an update,** the background service serves
  your saved choice. So do `darkbloom restart` and `darkbloom update`: a
  service an earlier start left serving another way restarts as saved, and
  says so: `Restarting as saved: Darkbloom network (the service was set up for
  Both, me first).` None of them changes your saved choice: only a choice
  does (the question, `--choose`, a mode flag, or one of the app's below).
- **Scripts, and the Darkbloom app's Start buttons,** serve your saved choice,
  **Only me** included, which asks nothing, not even the models: the ones you
  last chose that are still on this Mac, else every one it can serve. With none
  saved, they serve the Darkbloom network, as before, with no local API and no
  new port.
- **The models:** a start for **Darkbloom network** or **Both, me first** that
  names none (`--model <id>`, `--all`) can't pick them without a terminal, so it
  says in one line to add them and stops, instead of waiting for an answer.
- **On a Mac in a pair,** a start without a terminal starts the pair, with or
  without `--opencode` or `--hermes`, and so does the app's Start: the pair
  serves its own model, and a line says so when the app named another
  ([Two Macs](#two-macs)). Your saved choice is for this Mac alone: it applies
  with `--solo`.
- **The app's choices are saved too:** its onboarding, its Autopilot and
  Studio's "Alongside the network" start **Both, me first** (`--local-endpoint`)
  and save it, whatever you saved before; Studio's "Local only" starts **Only
  me** in the background and saves it. The app's Start, Restart and Update then
  serve that choice, as login and the watchdog do.

<!-- pending LS-7: a Darkbloom network choice in the app, saved as its other two are. -->

You can also name the choice in the command, in a terminal or not:

| Flag | Serves |
|---|---|
| `--local` | Only me |
| `--network` | Darkbloom network |
| `--me-first` | Both, me first |
| `--local-endpoint` | Both, me first (the older flag; a saved `--no-me-first` stays) |

**A flag saves your choice**, as the question does, so the background service,
`darkbloom restart` and `darkbloom update` serve it from now on. Two flags that
disagree are refused, for example `--local --me-first`.

**Only me in this Terminal window, for now:** `darkbloom start --local --here`
serves **Only me** until you close the window or press Ctrl-C, and saves no
choice. While it runs, the background service stops, and it says so:
``Darkbloom network serving stops while this runs; it starts again with
`darkbloom start`.`` When it ends, it says what serves now:
``Only me in this terminal stopped; nothing serves on this Mac now. `darkbloom
start` serves it again as saved: Darkbloom network.``

## Me first

With **Both, me first**, Darkbloom pauses while you use this Mac:

- **What counts as using it:** a request of yours that this Mac's own models
  answer, through its local API. Listing models doesn't count, and neither does
  a request this Mac passes on to your other Macs.
- **While you use it:** Darkbloom sends no new requests here. Requests it sent
  before you started that have begun answering finish normally; none of them
  is cut off. Your models stay loaded.
- **When your request has to wait:** if this Mac's memory, or its room for
  requests, is taken when you send one, Darkbloom requests still waiting in
  this Mac's queue go back to the network. Each is served by another Mac, or
  gets a retryable "busy" error if the whole network is full, and it doesn't
  count against this Mac. Darkbloom requests this Mac has started, in their
  prompt or answering, finish. Your request then waits only for requests this
  Mac has started, Darkbloom's or your own. If they don't make room within 2
  minutes, it fails, as before.
- **When you stop:** Darkbloom traffic comes back by itself once none of your
  requests has run for 2 minutes.

To change the 2 minutes (1 to 120), start with `--me-first-idle <minutes>`.
To let Darkbloom keep serving while you use the Mac, start with
`--no-me-first`; `--me-first` turns it back on. Both are saved. This is not the
memory setting (`--idle-timeout`, `darkbloom idle`), which unloads models after
a quiet time.

## When this Mac can't take your request

Your requests go to this Mac first. When it doesn't serve the model, or is too
busy, they can go on, like the Darkbloom iPhone app:

| Your choice | Then |
|---|---|
| Only this Mac | This Mac's answer, always |
| Only my Macs (free) | Your other Macs, at no cost |
| My Macs first | Your other Macs, then the Darkbloom network, billed to your balance |

Requests from other machines never use the paid network; they can use this Mac
and your other Macs.

Choose with one command; it saves your choice and says what it means:

```bash
darkbloom route this-mac        # Only this Mac
darkbloom route my-macs         # Only my Macs (free)
darkbloom route my-macs-first   # My Macs first, then the network (billed)
```

The last two need your account API key, from the Darkbloom console, saved
with `darkbloom route key`; without it they save nothing and say so. The key
goes into this Mac's Keychain and is never printed. With a key saved, the
start question asks this too. A running local API uses a new choice, and a key
saved or removed, from its next request: no restart, and no model reload. The
details are in
[the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router).

## Your local API

With **Only me** or **Both, me first**, your tools use an address and a key on
this Mac, for example `http://127.0.0.1:8001/v1`:

- **The port:** one per Mac, saved in `[local] port` the first time. That
  first start, however it starts (the question, a saved choice, a flag or the
  app's buttons), keeps the port this Mac's local API already uses: the running
  API's, else the one its installed background service serves on. A Mac updated
  from 0.10.10, whose local API serves on 8000, keeps 8000, so your tools keep
  working: `Local API port: 8000 (saved; this Mac's local API already uses it).`
  Only a Mac with no local API at all takes the first free port from 8001 (8000
  is left for other local AI apps):
  `Local API port: 8001 (saved; 8000 is left for other apps).` Every later
  start uses the saved port, so your tools keep finding it. `--port <n>` picks
  another and saves it too; the start then says to set your tools up again. On
  a Mac in a pair, the pair's API or this Mac's port for it takes the same saved
  port ([Two Macs](#two-macs)).
- **If another program holds the port,** the local API can't listen. **Both, me
  first** keeps serving Darkbloom, and `darkbloom status` and `darkbloom local`
  say why and name a free port, for example ``Serving: Darkbloom and you, me
  first — the local API isn't up: port 8001 is in use (`darkbloom start --port
  8002`)``. **Only me** stops with the same advice (in its log, when it serves
  in the background: `darkbloom logs`). On a Mac in a pair they name
  `darkbloom start --solo --port <n>` instead. For the pair's API, which keeps
  the saved port too, free the port or set another `[local] port` in
  `provider.toml`, then run `darkbloom restart`.
- **The key:** `darkbloom local` shows the address and the key. No start
  screen prints the key. On a Mac in a pair, the pair's API, or this Mac's
  port for it, takes this Mac's own key too.
- **On your local network (LAN or tailnet):** the local API listens on this Mac
  only, unless you start with `--bind <address>`; it always needs the key
  unless you add `--no-auth`. Without a key your requests stay on this Mac:
  nothing is passed on to your other Macs or the network, and `start` and
  `status` say so.

## Use it from OpenCode or Hermes

Run `darkbloom --opencode` or `darkbloom --hermes` (or both), as you would run
`ollama launch` or `omlx launch`. Each runs `darkbloom start` with the flag, so
any `start` option goes with it, in any order:

```bash
darkbloom --opencode                # set OpenCode up
darkbloom --hermes                  # set Hermes Agent up
darkbloom --opencode --hermes --me-first
```

Then, in OpenCode, `/models` → Darkbloom. Hermes uses Darkbloom as its main
model.

- **Starts Darkbloom only if needed.** If this Mac's local API already runs,
  nothing restarts: `Darkbloom already serves on 127.0.0.1:8001; setting up
  OpenCode for it.` Otherwise `start` runs as usual, and the tools are set up
  once the local API answers: a background start waits up to 30 seconds for it,
  and **Only me**, which listens once its models are loaded, up to
  `[backend] startup_preload_timeout_secs` (120) more.
- **What it changes:** one `darkbloom` provider in OpenCode's
  `~/.config/opencode/opencode.jsonc` (or your existing `opencode.json`), and
  in Hermes' `~/.hermes/config.yaml`, where it also becomes the main model, as
  Ollama and oMLX do. Everything else in those files stays as it was.
- **Your key stays out of them.** The tools read it from Darkbloom's own key
  file, and `darkbloom --opencode` never prints it.
- **Undo in one line:** every change is backed up first, and the start prints
  the file it changed, the backup and the command that puts it back:

  ```text
  ✓ OpenCode can use Darkbloom: 3 models.
    Changed: ~/.config/opencode/opencode.jsonc (added the "darkbloom" provider; nothing else changed)
    Backup:  ~/.darkbloom/integrations/backups/opencode/opencode.jsonc.20261106T221500Z
    Use it:  in OpenCode, /models → Darkbloom. Your default model is unchanged.
    Undo:    cp '<backup>' '<file>'
  ```

  When your OpenCode config sets no default model, Darkbloom's first model
  becomes the default for new sessions, and the `Use it:` line names it
  instead (`new sessions use darkbloom/<model>`).
- **It waits for your model.** While this Mac still loads the models it started
  with, the start waits before it writes anything, on one live line
  (`⠙ Loading Gemma 4 26B before setting up OpenCode… 42s`; without a terminal,
  one line as it starts and one as it ends). So the tools get the limits this
  Mac gives each model, not the catalog's. It waits at most 10 minutes: a model
  still loading then, or one that doesn't load, sets nothing up, and the line
  names the next step. Ctrl-C stops the wait; nothing is written, and the start
  says so, also when the model finishes loading just then. Darkbloom keeps
  serving either way. On one Mac only for now: a pair's local API isn't waited
  for (a pair started without a terminal already waits up to 10 minutes for the
  pair to serve).
- **What the tools get:** once a model is loaded, its whole context window from
  this Mac, and a quarter of it as their output limit (65,536 tokens for a
  262,144-token window), not the catalog's smaller one. On a pair, they get
  the pair's own limits, which it serves. For a model this Mac or its pair
  serves, they get image input exactly when it serves images, whatever
  Darkbloom's catalog says: MiMo V2.6 gets it on one Mac, loaded or not, though
  the catalog lists it as text only, and a Gemma 4 pair, which serves text
  alone, gets none. OpenCode likewise offers reasoning for exactly the models
  this Mac or its pair serves that reason (those that take every reasoning
  effort), so Qwen 3.8 27B gets it though the catalog doesn't say so. Hermes
  has no per-model reasoning setting, and sends your effort to every model:
  the ones that reason take it, the others ignore it. Your other Macs' models
  get the catalog's.
  <!-- pending R-FULL: the tools get each model's full output length. -->
- **Run it again** when your models change; with nothing new, it changes
  nothing. A model that isn't loading as it runs (one unloaded when idle, or
  one that loads on a request) gets the catalog's limits, and one line says to
  run it again once `darkbloom status` shows it loaded.
- **If the address or the key changes** (another port, another `--bind`, or
  another key file), the next `darkbloom start` says so in one line and names
  the command that points the tools there again:
  ``OpenCode points at http://127.0.0.1:8001/v1, not this Mac's local API
  (http://127.0.0.1:8002/v1): `darkbloom --opencode` points it there.`` A
  start without `--opencode` or `--hermes` never changes a tool's file.
  `localhost`, `127.0.0.1` and `::1` are all this Mac, and so is its `.local`
  name when the API listens on every address. On one Mac only for now: a
  paired Mac's start doesn't say it.
- **Offline** (Darkbloom's catalog unreachable), a run again keeps the names,
  image support, reasoning and limits already set up, but image input and
  reasoning for a model served here follow this Mac. A model set up for the
  first time then gets its ID, text input unless this Mac serves it with
  images, and reasoning if it reasons, and the start says to run it again
  online.
- **Hermes v0.20.2 or later** reads Darkbloom's key from its file; with an older
  Hermes the start still sets it up and says, in one line, to run
  `hermes update`.
- **When it can't:** it says why and changes nothing: the tool isn't installed
  (Darkbloom never installs it), OpenCode 1 (upgrade to OpenCode 2), Hermes
  needs a model with at least 64K context, or this Mac serves only the
  Darkbloom network (choose **Both, me first** or **Only me**). Darkbloom keeps
  serving either way.
- **Not with** `--network` (no local API) or `--no-auth` (the API would need no
  key). Beside a local API already running with `--no-auth`, it says so and
  starts nothing: start that API without `--no-auth` first.
- **If a tool reads another file:** with `OPENCODE_CONFIG_DIR` set, OpenCode
  reads only that folder, not `~/.config/opencode` (or `$XDG_CONFIG_HOME/opencode`),
  which Darkbloom changes: unset it, or copy the `darkbloom` provider there. A
  Hermes profile chosen with `hermes profile use <name>` reads
  `~/.hermes/profiles/<name>/config.yaml`: set that profile up with
  `HERMES_HOME=~/.hermes/profiles/<name> darkbloom --hermes`. The start
  always names the file it changed.

## Check how this Mac serves

`darkbloom status` says it in one line, for example:

```text
Serving: you first — Darkbloom paused for 10 minutes (your last request 1 minute ago; back in about 1 minute if you stay idle)
         2 Darkbloom requests are finishing
Your requests: this Mac first, then your other Macs (free) · account key saved
```

Times are said from now ("paused for under a minute", "back in about 2
minutes", "back any moment now"), never as a clock time, which an SSH session
or another Mac would read in a zone it doesn't see.

Other lines you may see:

- `Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)`
- `Serving: only you, on this Mac — Darkbloom never contacts this Mac`
- `Serving: only you, on this Mac — starting: its local API opens once its models are loaded`
- `Serving: Darkbloom network only — this Mac has no local API`
- ``Serving: Darkbloom and you, me first — the local API isn't up: port 8001 is in use (`darkbloom start --port 8002`)``

`darkbloom local` adds the same choice under the address.

## If you used `--local-endpoint` before

A Mac started with `--local-endpoint` serves **Both, me first**: Darkbloom
pauses while you use its local API, and comes back 2 minutes after. To keep the
old behaviour, where your requests and Darkbloom's share the Mac, start once
with `--local-endpoint --no-me-first`.

## Two Macs

A pair gets the same three choices. Run `darkbloom cluster` on each Mac: it
pairs them, then the leading Mac asks how the pair serves (**Only me**,
**Darkbloom network** or **Both, me first**, preselected) and which model; its
list's **Change how the pair serves** asks again. Then run
`darkbloom --opencode` on either Mac: with **Only me** or **Both, me first**,
each Mac answers at its own address, on its own saved port, with its own key.

- **Only me:** no Mac of the pair contacts Darkbloom. `darkbloom cluster local`
  serves the pair this way too. The other Mac passes its own port on to the
  pair's API, so `darkbloom local` and `--opencode` work there too, unless the
  API is kept on the leading Mac with `--bind`.
- **Both, me first:** the leading Mac runs the pair's API, and Darkbloom pauses
  for the whole pair while you use it. While it is paused, both Macs lose their
  base reward, counted in 5-minute periods; one Mac alone keeps it
  ([a pair's leader beside Darkbloom](./direct-mode.md#a-pairs-leader-beside-darkbloom)).
  The pair's API answers on your local network (LAN or tailnet), always with
  a key. Unless it is kept on the leading Mac with `--bind`, the other Mac
  passes its own port on to it too, as with **Only me**: `darkbloom local` and
  `--opencode` work there as well, and your requests there pause the pair too.
  While Darkbloom doesn't have the pair, it answers on the leading Mac only.
  `darkbloom status` on either Mac says whether the pair is paused for you,
  for how long and when it comes back (``Pair: you first — Darkbloom paused
  for 1 minute (…; back in about 2 minutes if you stay idle)``): the leading
  Mac's status carries it to the other Mac.
- Your answer is saved in `[local] mode` too. Without a terminal nothing is
  asked, and a pair keeps serving as it did
  ([Both, me first](./two-mac-cluster.md#both-me-first-the-pairs-own-api-beside-darkbloom)).

On a Mac in a pair, `darkbloom start` starts the pair, in a terminal or not,
also after `darkbloom stop`. The flags above are for serving this Mac alone:
add `--solo`. Without it they start nothing and say why; the app's Start, which
has no `--solo`, starts the pair. `darkbloom status` says under the pair when the
Mac serves alone ([Two Macs as one provider](./two-mac-cluster.md)).

## Related

- [Quickstart](./quickstart.md): from install to OpenCode on this Mac's models.
- [The local API](./direct-mode.md): its address, key, routes and the local router.
- [CLI reference](./cli-reference.md#how-this-mac-serves-one-question): every flag and line.
- [Configuration](../reference/configuration.md#local-first-use-local): the `[local]` keys.
- [Self-route](./self-route.md): use your Macs from a computer that doesn't run Darkbloom.
