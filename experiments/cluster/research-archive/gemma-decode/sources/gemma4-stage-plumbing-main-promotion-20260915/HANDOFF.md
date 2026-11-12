# Guarded Gemma Runtime additions

Ready for root review; MAIN has not been mutated. The proposed patch adds only the eight exact frozen Foundation Runtime files. No Package, existing Qwen source, profile, fingerprint, provider eligibility or native gate changes are permitted.

`promotion.json` requires every destination to be absent and pins all existing Runtime Swift files plus the cluster Package file. It also binds source freeze8317, runner correction6124, independent reviewfa8a and actual Foundation checksfa91074d (191 accepted /36 refused). `apply.py` defaults to verification only; `--apply` is reserved for root's explicit promotion grant. New files use exclusive creation and the receipt records each completed addition. A partial filesystem failure remains visible; the script does not overwrite or remove any file.

Review-only preflight:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/gemma4-stage-plumbing-main-promotion-20260915/apply.py
```

The metadata paths remain planning-only. Full payload verification, actual native construction, resource admission and numerical qualification remain outstanding.
