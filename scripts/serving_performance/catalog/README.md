# Reviewed deadline catalog

`deadline_profiles.json` is the sole reviewed data source for the Go and Swift
compiled deadline catalogs. It is currently empty: the initial Qwen3.8 M5
record was withdrawn because its receipts lack continuously sampled power
evidence. A fresh predeclared cohort must pass before promotion. Only copy a qualified **real**
evaluator candidate here after reviewing its raw receipt, independent holdout,
exact runtime identity, and evidence hashes. The generator does not qualify,
promote, retune, or synthesize records.

After an approved data edit, run from the repository root:

```sh
cd scripts
python3 -m serving_performance.catalog_codegen
python3 -m serving_performance.catalog_codegen --check
```

Commit the canonical JSON and both generated source files together. Generation
preserves values and array order, normalizes JSON object keys, and embeds exactly
the same UTF-8 JSON in both binaries. The Python wrapper suite checks that neither
source has drifted. Each runtime decodes its compiled constant once and disables
the entire catalog on a malformed, invalid, or duplicate-ID record. No runtime
provider/operator file is read. A deadline record cannot change serving width,
chunk policy, throughput curves, or memory admission.

`deadline_evidence.json` indexes the corresponding archived receipts;
it is not runtime configuration. Each entry names an assembled `receipt`
relative to the external `DARKBLOOM_QUALIFICATION_EVIDENCE_ROOT` directory and
binds it to the corresponding ordered catalog row through `profile_id`,
`qualification_report_sha256` and `profile_sha256`. The last digest covers the
entire profile serialized as UTF-8 JSON with sorted keys, compact separators,
unescaped Unicode, finite numbers and no trailing newline; array order remains
significant. IDs and canonical relative receipt paths must be unique. Its
`source_runs` references bind the intact training/validation receipt and
provenance files by archive-relative paths and actual content digests.
Normal CI checks every ID, report digest and full-profile digest against the
compiled catalog before any optional archive replay can skip. With the explicit
archive root, the offline test reassembles every observation, verifies the real prerequisite
files, reruns the independent coverage evaluator, and requires exact equality
with the compiled catalog. Missing indexed files and paths escaping the archive
fail validation; absent archives skip only the raw-evidence replay.
Cooled evidence retains its measured whole-Mac
quiescence, stable nominal and Automatic-on-AC requirements in the runtime
profile; it cannot certify arbitrary nominal-start requests.
