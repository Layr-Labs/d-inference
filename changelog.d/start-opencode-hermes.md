### `darkbloom start --opencode` and `--hermes`

- One flag sets OpenCode 2 or Hermes Agent up to use Darkbloom, as `ollama launch` and `omlx launch` do:
  `darkbloom start --opencode`, `--hermes`, or both. If this Mac's local API already runs, nothing restarts; otherwise
  `start` runs as usual and the tools are set up once its local API answers.
- It prints the file it changed, the backup and a one-line undo, then where your requests go and the two variables
  other OpenAI clients need (naming the key file, never the key). No line, and no tool file, holds the key.
- A Hermes older than v0.20.2 is set up with one warning line: it can't read the key until `hermes update`.
- A tool that isn't installed, OpenCode 1, Hermes without a 64K-context model, or a start that serves only the
  Darkbloom network: a plain `✗` line, nothing written, and Darkbloom keeps serving. Refused with `--network` and
  `--no-auth` (and with `--distributed`). Beside a running `--no-auth` local API, it says so and starts nothing.
- Without Darkbloom's catalog (offline, or the coordinator down), a run again keeps each model's name, image support
  and limits as they were set up, changes nothing, and says the catalog wasn't reachable. A model set up for the first
  time then gets its ID and text input only, and one line says to run the start again online for its name and image
  support.
- A model that isn't loaded yet gets one line: run the start again once it is, to pick up its limits. See
  [Use it from OpenCode or Hermes](docs/provider/local-first.md#use-it-from-opencode-or-hermes), which also
  covers `OPENCODE_CONFIG_DIR` and Hermes profiles.
