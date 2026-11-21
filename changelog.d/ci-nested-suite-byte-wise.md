### Provider CI: the nested-suite gate reads its log byte-wise

- `scripts/run-nested-suite.sh` checks the executed count and the skips of a `swift test` run with `LC_ALL=C grep`. SwiftPM's own warnings share the pipe with the test run's output, and one can land inside a line's leading glyph. In a UTF-8 locale macOS grep skips such a line: in run 44903589432 it missed `✔ Test run with 29 tests` and failed the selection as "executed ZERO tests", and on a skip line it would have let the skip pass.
- `scripts/verify-prompt-parity.sh` (Prompt Parity) runs the same two checks on its own `swift test` log, now also byte-wise.
