### The installer ends with `darkbloom --opencode`

- The installer's last lines say that `darkbloom --opencode` asks how this Mac serves (Only me, Darkbloom network, or
  Both, me first), then sets OpenCode up (`/models` → Darkbloom; `darkbloom --hermes` for Hermes), and that two Macs
  pair with `darkbloom cluster` on each. The last line is the command to run next, with its full path so it works
  before the shell picks up the new `PATH` line: `Next: ~/.darkbloom/bin/darkbloom --opencode`. Before, it listed
  `doctor`, `models catalog`, `models download`, `login` and `start`.
- `curl … | bash` prints these lines once the platform's copy of the installer is updated.
