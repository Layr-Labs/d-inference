# Prospective expected agreement

Derived after the comparator freeze and before reading any generation candidate sidecar. `derivation-1/expected-agreement.json` is the complete descriptor for the declared membership epoch 4eb14d7e-ebde-40e2-84e3-048667c7d9e1 and matched request 6426b803-8b80-40ba-8944-b0f4b403a3cf. Its native domain-separated agreement fingerprint is d43c2c42cffd415a52b1864778987fa97c55bd5577dbca14b8a57ac9846452ce.

The source-derived arithmetic receipt hashes to 0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74. Both old attempt9 cut-4 Ready records report common storage commitment e2e41be21c400e180645a3c0a10e8905ca71b4a48d558c8406c5dd0e66f0bb4f. This is retained opaque metadata from those earlier source-load receipts; it is not a new proof of loaded weights or storage. The current owner declarations supply both expected ae0775… worker build identities. Reading a configuration does not attest execution.

`derive.py --output-directory NEW_DIRECTORY` rehashes every frozen comparator member, reads bounded configuration/source/old-receipt snapshots, checks their identity joins, reproduces the native agreement formula, and rechecks all snapshots. It never opens a generation candidate. Its source receipt lists all actual input pins.

Copy `packet-template.json` outside this frozen directory and replace only the two candidate path/hash placeholders after the root retains the actual sidecars. Hash the complete resulting raw packet and pass it to the frozen comparator. If the membership epoch or other declaration changes, derive a new expected descriptor before the new run; never alter an expected descriptor to accommodate a candidate output.
