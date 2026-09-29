# Reviewed deadline catalog

`deadline_profiles.json` is the sole reviewed data source for the Go and Swift
compiled deadline catalogs. It starts empty. Only copy a qualified **real**
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
