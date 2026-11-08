### `darkbloom --opencode` and `darkbloom --hermes`

- `darkbloom --opencode` is `darkbloom start --opencode`, and `darkbloom --hermes` is `darkbloom start --hermes`;
  both together work too. Any other `start` option goes with them, in any order (`darkbloom --opencode --me-first`,
  `darkbloom --me-first --opencode`), and `start`'s errors and refusals apply. `darkbloom start --opencode` keeps
  working; `--help`, `--version`, plain `darkbloom` and every subcommand are unchanged, and a mistyped flag
  (`darkbloom --opencod`) gets the usual unknown-option error.
- `darkbloom --help` shows the two shortcuts, one line each.
- The lines that name the command say the short form: `darkbloom local`'s `tools:` line, the line `--port` prints
  when it replaces a saved port, the refusals, the tool step's lines, the installer's closing lines, and the comment
  above the `darkbloom` block in OpenCode's and Hermes' configs (a config set up before keeps its line).
