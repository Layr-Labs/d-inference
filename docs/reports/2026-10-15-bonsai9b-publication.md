# Bonsai 9B publication delay

> Last updated: 2026-10-15

Bonsai 9B publication was delayed by incorrect storage-access assumptions and
by treating upload access as a prerequisite for registry work. The model bytes
were already downloadable. This report records the incident and the narrower
workflow that resolved it; it contains no credentials.

## What went wrong

- **Access was inferred instead of checked.** The initial account endpoint was
  wrong, and available VM/GitHub credentials returned `AccessDenied` for the
  model bucket. Credentials used for release artifacts were not a verified
  source of model-bucket access. Two CI attempts failed before publishing:
  [first run](https://github.com/Layr-Labs/d-inference/actions/runs/38799770062),
  [second run](https://github.com/Layr-Labs/d-inference/actions/runs/38799964456).
- **Upload and registration were conflated.** The agent repeatedly treated R2
  write access as blocking all registration work. Registration consumes a
  published manifest through the coordinator; it does not inherently require
  the operator to upload model bytes. A valid canonical upload should be reused.
- **The backup was not the final serving inventory.** Its eleven files included
  the main model and two optional `mtp/` assistant files. The runtime recursively
  loads safetensors, and the assistant has unprefixed tensors. The serving
  revision therefore needed the nine main-model files, with unchanged weights.
  A public URL alone did not establish that this combined inventory was safe.
- **Recovery paths added delay.** A large single-object copy exceeded the local
  wait deadline; an expired GCP login later interrupted credential retrieval.
  Neither was a model-quality failure. A timeout did not establish whether a
  remote copy had completed.

## Resolution and evidence

An explicitly authorized, temporary insert-only registry recovery selected the
nine existing files. It was superseded by the normal canonical publication;
direct database insertion is not the recommended operational path.

After the bucket owner supplied the correct access details, an AWS Mac downloaded
the full pinned Hugging Face repository, including MTP, and all 31 files passed
checksum verification. Only the nine serving files were uploaded to the new
immutable revision `2026-10-15-base-r2`. The original backup was preserved.

The [revision-only workflow](https://github.com/Layr-Labs/d-inference/actions/runs/38801692053)
promoted that revision at 13:24 Pacific. Its
[canonical manifest](https://models.darkbloom.ai/v2/EigenLabs-Ternary-Bonsai-2-9B-MLX-2bit--e6e52cb29efb/2026-10-15-base-r2/manifest.json)
contains nine files, 3,475,181,460 bytes, and aggregate SHA-256
`3bfbed188a821cb7b16321b6be54245c6b162fc7d0ea064d5f663d0b07ee713d`.
At 13:29 Pacific, the public Darkbloom API returned HTTP 200 and `BONSAI_OK`.
This established basic text serving, not full-context or capability qualification.

## Prevention

Use the [publishing decision and access checks](../operations/model-revisions.md#choose-the-operation-first)
before requesting credentials. Keep registry-only work free of R2 dependencies;
verify the model bucket's endpoint and credential source before uploads; inspect
assistant/base layouts; publish a new version when inventory changes; and verify
both catalog state and a real public API response. The reusable workflow sends
only revision identity for an existing model and preserves its metadata/prices.
The one-off Bonsai upload path using release credentials is removed.
