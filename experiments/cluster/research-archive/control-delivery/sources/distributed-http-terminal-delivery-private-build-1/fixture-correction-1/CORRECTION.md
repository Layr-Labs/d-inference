# First Provider fixture compile correction

Attempt 2 compiled the combined runtime and failed compiling tests. Both original
frozen HTTP packages and attempt 2 source/log receipts remain unchanged.

This five-file correction adds explicit `try` to two throwing first-token-policy
initializers, awaits two actor-owned response-registry reads, evaluates a throwing
failure-frame expression before the Testing `require` macro, and changes the
existing HTTPOrigin direct-call helper to the new outer application's
`LocalConnectionRequestContext`. That context still carries its same embedded
channel/logger; the same outer origin/auth path is exercised. All test assertions,
policy deadlines, socket cases, and 26 new method bodies' intended behavior are
preserved. Runtime source and production behavior are unchanged.

`integration.json` pins every original/final fixture, including the pre-existing
MAIN HTTPOrigin helper absent from the first 20-file overlay. Eventual MAIN
integration therefore has 21 files. No MAIN source was changed. This correction
is prepared for a separate retained attempt; it is not a passing test result.
