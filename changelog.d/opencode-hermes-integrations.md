### OpenCode and Hermes: the config writers for `start --opencode` and `--hermes`

- The writers that make OpenCode 2 and Hermes Agent ready to use Darkbloom as a provider. No command calls them yet:
  the `darkbloom start --opencode` / `--hermes` flags come with the one start screen.
- OpenCode gets a `providers.darkbloom` block in its global `opencode.jsonc` (or an existing `opencode.json`): the
  local endpoint at its live port from `local.json`, the models with their names, context and output limits and
  capabilities, and `max_tokens` as the output-cap field (OpenCode otherwise sends `max_completion_tokens`, which the
  engine ignores, so a long answer would stop at its 4,096-token default). Its default model is set only when it has
  none.
- Hermes gets `providers.darkbloom` (`key_cmd`, `extra_body.max_tokens`, each model's context and vision) and
  Darkbloom as its main model in `~/.hermes/config.yaml`, as `ollama launch` and `omlx launch` make theirs. Models
  under Hermes' 64,000-token floor are left out, and none at or above it refuses.
- Neither file ever holds the key: OpenCode reads it with `{file:~/.darkbloom/local_token}`, Hermes with
  `key_cmd: /bin/cat …`. Every comment and key the edit doesn't own stays; a second run with the same models writes
  nothing; a change first backs the file up to `~/.darkbloom/integrations/backups/` (five kept per file), replaces it
  atomically and comes with an exact undo command. A file Darkbloom can't edit safely (invalid, YAML anchors, several
  documents) is refused, unchanged.
- `scripts/integrations/opencode-smoke.sh` runs the real OpenCode on the written config in a throwaway home against a
  fake server.
