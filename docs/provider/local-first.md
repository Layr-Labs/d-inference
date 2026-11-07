# Use your Mac yourself, first

> Last updated: 2026-11-07

How your Mac serves is one choice: **Only me**, **Darkbloom network** or
**Both, me first**. This page says what each one runs, costs and earns, how to
choose and switch, and how your tools (OpenCode, Hermes, any OpenAI client)
use your Mac's models.

| Choice | What runs | Where your requests go | Costs and earnings | What stops it |
|---|---|---|---|---|
| **Only me** | Your models, on this Mac's local API (`http://127.0.0.1:<port>/v1`) | To this Mac. Darkbloom never contacts it | Free. Earns nothing; needs no account | `darkbloom stop` |
| **Darkbloom network** | Darkbloom's requests. No local API | Nowhere here: your tools have no address on this Mac | Earns while it serves; needs your account (`darkbloom login`) | `darkbloom stop` |
| **Both, me first** | Darkbloom's requests, and a local API for you on `http://127.0.0.1:<port>/v1` | To this Mac first: Darkbloom pauses while you use it and comes back after 2 idle minutes | Yours are free; Darkbloom's earn while you aren't using the Mac | `darkbloom stop` |

Every choice serves in the background: it starts at login, starts again after
a crash, updates itself, and keeps the Mac awake while it serves (the display
can still sleep). <!-- pending LS-1 --> With an account key saved, a request this Mac can't
take can go on to your other Macs, free, or to the network, billed, if you
choose ([below](#when-this-mac-cant-take-your-request)).

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

Press Enter for **Both, me first**, or type 1, 2 or 3. Then, whichever you
chose, `start` asks which models to serve (it downloads the ones you pick) and
what to do with memory when idle, and serves in the background. <!-- pending LS-1 -->

- **Your answer is saved** in the `[local]` section of `provider.toml`, and later
  starts don't ask again.
- **Nothing is saved until the start goes ahead.** If you cancel the model
  picker, or press Ctrl-D at the question, nothing changes.
- **To serve Only me in this terminal instead**, run
  `darkbloom start --local --here`: closing the window, or Ctrl-C, stops it. <!-- pending LS-1 -->

## Switch

```bash
darkbloom mode only-me        # or: darkbloom mode network, darkbloom mode both
```

`darkbloom mode` saves the new choice and serves that way at once, with the same
models, the same address and the same key, so the tools you set up keep
working. <!-- pending LS-2 --> <!-- pending LS-1 --> `darkbloom start --choose` asks the whole
start again, models and memory included.

## No terminal, no question

Starts without a terminal never ask: the service that macOS starts at login,
the Darkbloom app and scripts. Once you've chosen, they serve your choice,
**Only me** included. <!-- pending LS-1 --> The app's buttons keep your choice too. <!-- pending LS-2 -->
Until you choose, they serve the Darkbloom network as before, with no local API
and no new port. <!-- pending LS-2 -->

You can also name the choice for one start, in a terminal or not:

| Flag | Serves |
|---|---|
| `--local` | Only me |
| `--network` | Darkbloom network |
| `--me-first` | Both, me first |
| `--local-endpoint` | Both, me first (the older flag; it keeps a saved `--no-me-first`) |

A flag is for that start only; it doesn't change your saved choice. Two that
disagree are refused, for example `--local --me-first`.

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

With **Only me** or **Both, me first**, your tools use one address and one key
on this Mac, for example `http://127.0.0.1:8001/v1`:

- **One port per Mac:** the first start takes the first free port from 8001
  (8000 is left for other local AI apps), saves it in `[local] port` and says
  which: `Local API port: 8001 (saved; 8000 is left for other apps).` Every
  later start uses it, whatever you chose, the app's and a pair's included, so
  your tools keep finding it. <!-- pending LS-1 --> `--port <n>` picks one yourself.
- **One key per Mac:** the same key for every choice and for a pair. <!-- pending LS-1 -->
  `darkbloom local` shows the address and the key. No start screen prints the
  key.
- **On your local network (LAN or tailnet):** the local API listens on this Mac
  only, unless you start with `--bind <address>`; it always needs the key
  unless you add `--no-auth`. Without a key your requests stay on this Mac:
  nothing is passed on to your other Macs or the network, and `start` and
  `status` say so.

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
  once the local API answers.
- **Waits for your model.** A start that loads a model waits until it is
  loaded, on one line that updates as it goes, then sets the tools up with
  that model's limits. <!-- pending LS-4 -->
- **The whole model.** The tools get each model's full context window and
  output length, and every capability it has: images, tools, reasoning. <!-- pending R-FULL -->
- **Keeps pointing at this Mac.** When the address or the key changes, or you
  switch with `darkbloom mode`, the tools follow by themselves. <!-- pending LS-4 --> <!-- pending LS-2 -->
- **What it changes:** one `darkbloom` provider in OpenCode's
  `~/.config/opencode/opencode.jsonc` (or your existing `opencode.json`), and
  in Hermes' `~/.hermes/config.yaml`, where it also becomes the main model, as
  Ollama and oMLX do. Everything else in those files stays as it was.
- **Your key stays out of them.** The tools read it from Darkbloom's own key
  file, and no screen prints it.
- **Undo in one line:** every change is backed up first, and the start prints
  the file it changed, the backup and the command that puts it back:

  ```text
  ✓ OpenCode can use Darkbloom: 3 models.
    Changed: ~/.config/opencode/opencode.jsonc (added the "darkbloom" provider; nothing else changed)
    Backup:  ~/.darkbloom/integrations/backups/opencode/opencode.jsonc.20261106T221500Z
    Use it:  in OpenCode, /models → Darkbloom. Your default model is unchanged.
    Undo:    cp '<backup>' '<file>'
  ```

- **Run it again** when your models change; with nothing new, it changes
  nothing.
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
list's **Change how the pair serves** asks again. Then `darkbloom start --opencode` on either Mac
sets OpenCode up there: every Mac of the pair answers on its own
`http://127.0.0.1:<port>/v1`, with one key. <!-- pending LS-3 --> <!-- pending LS-1 -->

- **Only me:** no Mac of the pair contacts Darkbloom. `darkbloom cluster local`
  serves the pair this way too.
- **Both, me first:** the leading Mac runs the pair's API, and Darkbloom pauses
  for the whole pair while you use it. Today, while it is paused and for the 2
  minutes after, both Macs earn no base reward (one Mac alone keeps it). The
  pair's API answers on your local network (LAN or tailnet), always with the
  key.
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
