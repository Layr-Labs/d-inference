### Model Requant Upload workflow

- New `workflow_dispatch` workflow, **Model Requant Upload**, dispatched from `master` only. It re-quantizes an existing model's language-model linears from its pinned bf16 source with `scripts/models/requant.py`. It checks the result byte for byte against the canonical manifest of the locally qualified candidate, then reserves and uploads it to `darkbloom-models` with the repository's R2 secrets, manifest last. It never registers or promotes.
- Its tools are installed by hash. Before any secret is in scope, a seconds-long `requant.py selftest` checks the quantizer against recorded digests. The manifest must be one that Register and every provider read, `created_at` included. A credentialed step stops on an empty secret, and the read check never prints the endpoint.
- Runbook: `docs/operations/model-revisions.md`, "Re-quantize and upload from CI". Tests: `scripts/models/test_model_requant_upload.py`, run by Release Integrity.
