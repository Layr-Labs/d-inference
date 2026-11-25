# Preserved cluster research: qwen-prefill

Source snapshot captured 2026-09-28 for later review and fixes. This archive holds
2,084 distinct source/document versions from the private research workspace.
The implementation has not been integrated or corrected.

`source-index.json` maps every retained source to its original relative locations
and SHA-256 of the published bytes. Identical copies share one file; distinct
versions retain separate files. Paths are relative to this archive. Source files
retain their original names under `sources/`.

The main checkout, its three modified MLX repositories, and the other research
categories are separate draft PRs. Files identical to the captured main checkout
or already present as local Git blobs were not copied into this archive again.
Unchanged third-party environments (including the clean exo checkout), build
outputs, model weights, raw benchmark receipts/logs, private machine inventories,
TLS material and SSH credentials are excluded. This is a source preservation PR,
not a self-contained replay of every historical hardware experiment.

Personal home paths, private network addresses, owner login names and hardware
network addresses were replaced with documentation placeholders where present.
`privacy_redacted` identifies affected files. Embedded historical hashes and
absolute paths may consequently require rebinding before an experiment can run.
No archived launcher has been executed as part of this import.

Archive modules and patches are alternatives and successive drafts; applying all
of them together is not supported. The Gemma decode union remains an unqualified
candidate, and the retained notes describe numerical mismatches and runs slower
than solo inference. Those limitations have not been fixed by this import.

Validation: all published file hashes and index references checked, Gitleaks run
with reviewed findings limited to code identifiers, public fixture constants,
content canaries and artifact hashes; additional privacy-pattern checks run.
