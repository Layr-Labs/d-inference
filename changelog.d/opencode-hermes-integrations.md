### OpenCode and Hermes: the config writers for `start --opencode` and `--hermes`

- The writers that make OpenCode 2 and Hermes Agent ready to use Darkbloom as a provider. No command calls them yet:
  the `darkbloom start --opencode` / `--hermes` flags come with the one start screen.
- OpenCode gets a `providers.darkbloom` block in its global `opencode.jsonc` (or an existing `opencode.json`): the
  local endpoint at its live port from `local.json`, the models with their names, context and output limits and
  capabilities, and `max_tokens` as the output-cap field (OpenCode otherwise sends `max_completion_tokens`, which the
  engine ignores, so a long answer would stop at its 4,096-token default). Its default model is set only when no
  global config file sets one: with both files, the owner's default in `opencode.json` stays in effect.
- Hermes gets `providers.darkbloom` (`key_cmd`, `extra_body.max_tokens`, each model's context and vision) and
  Darkbloom as its main model in `$HERMES_HOME/config.yaml` (`~/.hermes/config.yaml` by default), as `ollama launch`
  and `omlx launch` make theirs. Models under Hermes' 64,000-token floor are left out, and none at or above it
  refuses. A file in PyYAML's style, with lists at their key's indent as oMLX writes it, is edited and its lists kept.
- Hermes needs v0.20.2 or later, which added `key_cmd` (an older Hermes sends no key); the start flag warns in one
  line when the installed Hermes is older. An open Hermes bug (#124289) can drop `max_tokens` after a `/model … --provider <bare name>` switch, so
  those turns get the engine's 4,096-token default.
- Neither file ever holds the key: OpenCode reads it with `{file:~/.darkbloom/local_token}`, Hermes with
  `key_cmd: /bin/cat …`. Every comment and key outside the `darkbloom` block stays (the block itself is rewritten
  whole); a second run with the same models writes nothing; a change first backs the file up to
  `~/.darkbloom/integrations/backups/` (five kept per file name), replaces it atomically and comes with an exact undo
  command. A file Darkbloom can't edit safely (invalid, YAML anchors, several documents) is refused, unchanged.
- `scripts/integrations/opencode-smoke.sh` runs the real OpenCode on the written config in a throwaway home against a
  fake server.
