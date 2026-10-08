# Diagnostic fixture SDK correction

Exact one-line change from 7f0: the diagnostic-only NWError switch uses default, so the current SDK's known wifiAware case is rendered rather than rejected at compile time. No runtime anchor, trust policy, acceptance/classification, TLS server, parser, ownership or deadline change. Original e0 actual failure and 7f0 Swift compile failure remain untouched.

Future granted command: python3 -B Tests/run_tls.py 1, regular outer logs. No execution by author. Exact runtime anchor remains frozen e0 b68c. Parent must require all six actual TLS/URL controls; a network error or timeout still fails, and this diagnostic correction is not TLS qualification.
