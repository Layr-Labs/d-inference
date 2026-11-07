# Use your Mac yourself, first

> Last updated: 2026-11-07

How your Mac serves is one choice: **Only me**, **Darkbloom network** or
**Both, me first**. This page says what each one runs, costs and earns, how to
choose and switch, and how your tools (OpenCode, Hermes, any OpenAI client)
use your Mac's models.

| Choice | What runs | Where your requests go | Costs and earnings | What stops it |
|---|---|---|---|---|
| **Only me** | The models already on this Mac, on its local API (`http://127.0.0.1:<port>/v1`), in the Terminal window that started it | To this Mac. Darkbloom never contacts it | Free. Earns nothing; needs no account | Ctrl-C, closing that window, or `darkbloom stop` |
| **Darkbloom network** | Darkbloom's requests, in the background. No local API | Nowhere here: your tools have no address on this Mac | Earns while it serves; needs your account (`darkbloom login`) | `darkbloom stop` |
| **Both, me first** | Darkbloom's requests, and a local API for you on `http://127.0.0.1:<port>/v1`, in the background | To this Mac first: Darkbloom pauses while you use it and comes back after 2 idle minutes | Yours are free; Darkbloom's earn while you aren't using the Mac | `darkbloom stop` |

In the background means it starts at login, starts again after a crash and
updates itself. Every choice keeps the Mac awake while it serves (the display
can still sleep). **Only me** first stops a background service that was
running, so once its window closes, nothing serves until the next
`darkbloom start`. With an account key saved, a request this Mac can't take can
go on to your other Macs, free, or to the network, billed, if you choose
([below](#when-this-mac-cant-take-your-request)).

<!-- pending LS-1: Only me serves in the background too, with the model list and the memory question, and stops only with darkbloom stop. -->

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

- **Darkbloom network** and **Both, me first** ask which models to serve (the
  list downloads the ones you pick) and what to do with memory when idle, then
  serve in the background.
- **Only me** asks neither: it serves every model already on this Mac that it
  can, in this Terminal window. On a Mac with no model yet it stops with
  `No engine-v2-capable models available to serve.`: download one first
  (`darkbloom models catalog`, then `darkbloom models download <id>`), or
  choose **Both, me first**, whose list downloads it.
- **Your answer is saved** in the `[local]` section of `provider.toml`, and later
  starts don't ask again.
- **Nothing is saved until the start goes ahead.** If you cancel the model
  picker, or press Ctrl-D at the question, nothing changes.

## Switch

```bash
darkbloom start --choose
```

It asks the question again, in a terminal, and goes on as a first start does:
the model list and the memory question again for **Darkbloom network** and
**Both, me first**. It saves the new answer.

<!-- pending LS-2: a one-step switch that saves the choice and keeps the models, the address and the key, so the tools keep working. -->

## No terminal, no question

Starts without a terminal never ask:

- **At login, and after a crash or an update,** the background service serves
  the way the last `darkbloom start` set it up.
- **Scripts, and the Darkbloom app's Start buttons,** serve your saved choice.
  With none saved, they serve the Darkbloom network, as before, with no local
  API and no new port.
- **A saved Only me** serves in a terminal, so a start without one says so and
  stops before it changes anything.
- **Some app buttons choose for you:** the app's onboarding, its Autopilot and
  Studio's "Alongside the network" start **Both, me first** (`--local-endpoint`)
  whatever you saved; Studio's "Local only" starts **Only me** in the
  background.

<!-- pending LS-2: the app passes no mode flag, so its buttons keep your saved choice. -->

You can also name the choice in the command, in a terminal or not:

| Flag | Serves |
|---|---|
| `--local` | Only me |
| `--network` | Darkbloom network |
| `--me-first` | Both, me first |
| `--local-endpoint` | Both, me first (the older flag; a saved `--no-me-first` stays) |

A flag doesn't change your saved choice, but the background service it starts
keeps it: at login, after `darkbloom restart` and after an update it serves
that way again, until the next `darkbloom start` without a flag goes back to
your saved choice. `--local` serves in the Terminal window, so it ends with
it. Two flags that disagree are refused, for example `--local --me-first`.

## Me first

With **Both, me first**, Darkbloom pauses while you use this Mac:

- **What counts as using it:** a request of yours that this Mac's own models
  answer, through its local API. Listing models doesn't count, and neither does
  a request this Mac passes on to your other Macs.
- **While you use it:** Darkbloom sends no new requests here. Requests it sent
  before you started finish normally; nothing is cut off. Your models stay
  loaded.
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

This needs your account API key, from the Darkbloom console, saved with
`darkbloom route key`. It goes into this Mac's Keychain and is never printed.
With a key saved, the question asks this too; you can also start with
`--route this-mac`, `--route my-macs` or `--route my-macs-first`. The details
are in [the local router](./direct-mode.md#when-this-mac-cant-take-a-request-the-local-router).

## Your local API

With **Only me** or **Both, me first**, your tools use an address and a key on
this Mac, for example `http://127.0.0.1:8001/v1`:

- **The port:** a local API that the question, a saved choice or `--me-first`
  starts takes the first free port from 8001 (8000 is left for other local AI
  apps), saves it in `[local] port` and says which:
  `Local API port: 8001 (saved; 8000 is left for other apps).` Later starts
  keep it, so your tools keep finding it. `--local`, `--local-endpoint` and the
  app's buttons use `[local] port` too, or 8000 when none is saved, and a pair's
  API picks its own ([Two Macs](#two-macs)). `--port <n>` picks one yourself.
- **The key:** `darkbloom local` shows the address and the key. Of the start
  screens, only `darkbloom start --local`'s prints the key. A pair's API has a
  key of its own, the same on both Macs.
- **On your local network (LAN or tailnet):** the local API listens on this Mac
  only, unless you start with `--bind <address>`; it always needs the key
  unless you add `--no-auth`. Without a key your requests stay on this Mac:
  nothing is passed on to your other Macs or the network, and `start` and
  `status` say so.

<!-- pending LS-1: one port, chosen once from 8001, and one key per Mac, for every way of starting, the app's and a pair's included. -->

## Use it from OpenCode or Hermes

Add `--opencode` or `--hermes` (or both) to `darkbloom start`, as you would run
`ollama launch` or `omlx launch`:

```bash
darkbloom start --opencode          # set OpenCode up
darkbloom start --hermes            # set Hermes Agent up
darkbloom start --me-first --opencode --hermes
```

Then, in OpenCode, `/models` → Darkbloom. Hermes uses Darkbloom as its main
model.

- **Starts Darkbloom only if needed.** If this Mac's local API already runs,
  nothing restarts: `Darkbloom already serves on 127.0.0.1:8001; setting up
  OpenCode for it.` Otherwise `start` runs as usual, and the tools are set up
  once the local API answers: a background start waits up to 30 seconds for it.
- **What it changes:** one `darkbloom` provider in OpenCode's
  `~/.config/opencode/opencode.jsonc` (or your existing `opencode.json`), and
  in Hermes' `~/.hermes/config.yaml`, where it also becomes the main model, as
  Ollama and oMLX do. Everything else in those files stays as it was.
- **Your key stays out of them.** The tools read it from Darkbloom's own key
  file, and `start --opencode` never prints it.
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
- **Run it again** when your models change, or when the port or the key
  changes; with nothing new, it changes nothing. Run it again too once a model
  you just started is loaded: until then this Mac doesn't know its limits, the
  tools get the catalog's, and the start says so.
  <!-- pending LS-4: the start waits for the model to load before it writes the limits, and the tools follow the address and the key by themselves. -->
  Once a model is loaded, the tools get its whole context window from this
  Mac, and a quarter of it as their output limit (65,536 tokens for a
  262,144-token window), not the catalog's smaller one.
  <!-- pending R-FULL: the tools get each model's full output length and all its capabilities. -->
- **Offline** (Darkbloom's catalog unreachable), a run again keeps the names,
  image support and limits already set up. A model set up for the first time
  then gets its ID and text input only, and the start says to run it again
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
  `HERMES_HOME=~/.hermes/profiles/<name> darkbloom start --hermes`. The start
  always names the file it changed.

## Check how this Mac serves

`darkbloom status` says it in one line, for example:

```text
Serving: you first — Darkbloom paused since 14:02 (your last request 1 minute ago; back at about 14:13 if you stay idle)
         2 Darkbloom requests are finishing
Your requests: this Mac first, then your other Macs (free) · account key saved
```

Other lines you may see:

- `Serving: Darkbloom and you, me first — open to Darkbloom (none of your requests in the last 2 minutes)`
- `Serving: only you, on this Mac — Darkbloom never contacts this Mac`
- `Serving: Darkbloom network only — this Mac has no local API`

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
`darkbloom start --opencode` on the leading Mac, which runs the pair's API.

- **Only me:** no Mac of the pair contacts Darkbloom. `darkbloom cluster local`
  serves the pair this way too. The other Mac passes its own port on to the
  pair's API, so `darkbloom local` and `--opencode` work there too, unless the
  API is kept on the leading Mac with `--bind`.
- **Both, me first:** the leading Mac runs the pair's API, and Darkbloom pauses
  for the whole pair while you use it. While it is paused, both Macs lose their
  base reward, counted in 5-minute periods; one Mac alone keeps it
  ([a pair's leader beside Darkbloom](./direct-mode.md#a-pairs-leader-beside-darkbloom)).
  The pair's API answers on your local network (LAN or tailnet), always with
  the key. The other Mac has no API of its own: tools there use the leading
  Mac's LAN or tailnet address.
  <!-- pending LS-3: the other Mac relays its own port in Both, me first too, so start with opencode works on either Mac. -->
- Your answer is saved in `[local] mode` too. Without a terminal nothing is
  asked, and a pair keeps serving as it did
  ([Both, me first](./two-mac-cluster.md#both-me-first-the-pairs-own-api-beside-darkbloom)).

On a Mac in a pair, `darkbloom start` starts the pair, and the flags above are
for serving this Mac alone: add `--solo`
([Two Macs as one provider](./two-mac-cluster.md)).

## Related

- [Quickstart](./quickstart.md): from install to OpenCode on this Mac's models.
- [The local API](./direct-mode.md): its address, key, routes and the local router.
- [CLI reference](./cli-reference.md#how-this-mac-serves-one-question): every flag and line.
- [Configuration](../reference/configuration.md#local-first-use-local): the `[local]` keys.
- [Self-route](./self-route.md): use your Macs from a computer that doesn't run Darkbloom.
