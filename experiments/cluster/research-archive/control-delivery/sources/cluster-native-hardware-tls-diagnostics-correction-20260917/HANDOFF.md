# Actual TLS fixture diagnostics

Original e0/tls-check-1 retained: both compiler children passed; valid handshake failed as other-failure, zero upgrades and empty server stderr. Cause is not yet established.

This successor changes only fixture observations: bounded actual NWError enum/code/description is saved before asserting, and the real listener counts accepted TCP sockets separately from completed TLS/WebSocket upgrades. IPv4 listener, localhost URL, TLS trust evaluator, certificate cases, timeouts and all success/refusal rules remain unchanged. Network failure is never a passing TLS-negative control. Group/owned helpers are exact e0. Runtime anchor is read directly from frozen e0, SHA b68c522383747f1f59222b008e6c44fddb6fd5047c8152bb0d08550bf239a635.

Future explicit compiler grant only: `python3 -B Tests/run_tls.py 1`, outer stdout/stderr to fresh regular files. Same jobs2, 90/90/60s bounds. No test/compiler/remote execution by author. All outputs are fresh under this successor; original failed evidence is untouched.
