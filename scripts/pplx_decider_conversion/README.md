# pplx-decider-v1-27b MLX conversion tools

These tools convert `perplexity-ai/pplx-decider-v1-27b` revision
`d8c3bd18e31dc1804433d38528b3e770019bf00c` into the tensor layout of the served
`EigenLabs/Qwen3.8-27B-4bit` pack, with the decider readout as the output
head. They do not download, upload, publish or register a model.

## Contract

- Pin: the SHA-256 of the release's `release-manifest.json` is fixed in
  `pplx_decider_provenance.py`. Every file the manifest lists must match its
  bytes and SHA-256. `LICENSE` and `NOTICE` are not in the manifest; their
  SHA-256 at the pinned revision is pinned in code too. The download marker
  `.download-complete` must contain `{"repo": "<repo>", "revision": "<sha>"}`.
- Names: mlx-vlm `qwen3_5` names. A leading `model.` is stripped,
  `language_model.X` becomes `language_model.model.X`, `visual.` becomes
  `vision_tower.`, `lm_head.weight` becomes `language_model.lm_head.weight`.
  `mtp.*` and `position_ids` tensors are dropped, as mlx-vlm drops them.
- Values: as mlx-vlm 0.5.0 sanitize does. `conv1d.weight` `[C,1,K]` becomes
  `[C,K,1]`. 1-D input, post-attention, final, q and k norms get `+1.0`
  (`linear_attn.norm` does not). Vision `patch_embed.proj.weight`
  `[O,Cin,T,H,W]` becomes `[O,T,H,W,Cin]`. Every source tensor must be BF16.
- Quantization: affine Q4, group 64, BF16 scales and biases, for every 2-D
  `language_model.*` tensor. A candidate whose last dimension is not a
  multiple of 64 stops the conversion; there is no g32 fallback. Norms,
  `conv1d`, `A_log`, `dt_bias` and the vision tower stay BF16.
- Head: `readout.safetensors` (`weight`, BF16 `[255, 5120]`) is written
  unquantized as `language_model.lm_head.weight` into the last shard. A
  source with both an `lm_head.weight` and a readout, or with neither, is
  refused.
- Files: one `format: mlx` shard per source shard, an index with
  `metadata.total_size` and `metadata.format: "mlx"`, `config.json`
  (`model_type: pplx_decider_qwen35`, `quantization` and
  `quantization_config`, and a `decision` block with `format_version`,
  `options`, `temperature`, `codes`, `token_ids` and `max_input_tokens: 8192`),
  verbatim `tokenizer.json`, `tokenizer_config.json`, `chat_template.jinja`,
  `decision_config.json`, `LICENSE`, `NOTICE`, the three processor files in
  the served layout with the decider's pixel limits, a private `README.md`,
  `shard-digests.json` and `conversion-receipt.json`.
- Conformance: the same code path converts `Qwen/Qwen3.8-27B` revision
  `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` (its `lm_head.weight` is
  quantized) and compares the result with `EigenLabs/Qwen3.8-27B-4bit`
  revision `301e9e2767fd0efcfab7883004720ba3c9a552a1`. Tensor names, shapes
  and dtypes must be identical. The report counts bit-identical tensors and
  gives a max abs diff for the others (dequantized for affine triples).

## Box procedure

Run on an M5 box with the mlx venv (`~/qwen38-convert-env`, `mlx` 0.32.0).
Use existing, verified storage with about 100 GB free. Run from a neutral
working directory.

```sh
VENV=~/qwen38-convert-env
TOOLS=/path/to/d-inference/scripts/pplx_decider_conversion
STORE=/path/to/verified/storage
SRC=$STORE/pplx-decider-v1-27b-d8c3bd18
BASE=$STORE/Qwen3.8-27B-1d4bf0f2
REF=$STORE/Qwen3.8-27B-4bit-301e9e27
LOCK='import fcntl,os,sys; fd=os.open("/tmp/mtplx-gpu-exclusive.lock", os.O_RDWR|os.O_CREAT, 0o666); fcntl.flock(fd, fcntl.LOCK_EX); os.set_inheritable(fd, True); os.execvp(sys.argv[1], sys.argv[1:])'
```

`LOCK` takes the GPU lock with `fcntl.flock` and keeps it across `exec`,
because macOS has no `flock(1)`. It waits while a ranked job holds the lock.

1. Download each tree and write its marker.

   ```sh
   "$VENV/bin/hf" download perplexity-ai/pplx-decider-v1-27b --revision d8c3bd18e31dc1804433d38528b3e770019bf00c --local-dir "$SRC"
   printf '{"repo": "%s", "revision": "%s"}\n' perplexity-ai/pplx-decider-v1-27b d8c3bd18e31dc1804433d38528b3e770019bf00c > "$SRC/.download-complete"
   "$VENV/bin/hf" download Qwen/Qwen3.8-27B --revision 1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0 --local-dir "$BASE"
   printf '{"repo": "%s", "revision": "%s"}\n' Qwen/Qwen3.8-27B 1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0 > "$BASE/.download-complete"
   "$VENV/bin/hf" download EigenLabs/Qwen3.8-27B-4bit --revision 301e9e2767fd0efcfab7883004720ba3c9a552a1 --local-dir "$REF"
   printf '{"repo": "%s", "revision": "%s"}\n' EigenLabs/Qwen3.8-27B-4bit 301e9e2767fd0efcfab7883004720ba3c9a552a1 > "$REF/.download-complete"
   ```

2. Verify the downloads. Each run exits 0 on success and 4 on failure.

   ```sh
   "$VENV/bin/python" -B "$TOOLS/verify_pplx_decider_download.py" --source "$SRC" --hash-shards --output-manifest "$STORE/pplx-decider-source-receipt.json"
   "$VENV/bin/python" -B "$TOOLS/verify_pplx_decider_download.py" --kind base --source "$BASE" --hash-shards
   "$VENV/bin/python" -B "$TOOLS/verify_pplx_decider_download.py" --kind reference --source "$REF" --hash-shards
   ```

3. Convert under the GPU lock. The output directory must not exist.

   ```sh
   python3 -c "$LOCK" "$VENV/bin/python" -B "$TOOLS/convert_pplx_decider_q4.py" --source "$SRC" --output "$STORE/pplx-decider-v1-27b-MLX-4bit"
   ```

4. Run the conformance check under the GPU lock. It exits 0 when names,
   shapes and dtypes match the served pack and 5 when they do not.

   ```sh
   python3 -c "$LOCK" "$VENV/bin/python" -B "$TOOLS/convert_pplx_decider_q4.py" --conformance-source "$BASE" --conformance-reference "$REF" --output "$STORE/conformance-Qwen3.8-27B-4bit" --conformance-report "$STORE/conformance-report.json"
   ```

   To compare two existing packs again without converting, run
   `compare_pack_layout.py --ours <pack> --reference <pack> --report <new.json>`
   under the lock.

Keep `conversion-receipt.json`, `shard-digests.json`, the source receipt and
the conformance report. Publication, upload and catalog registration are
separate owner decisions.

## Tests and qualification limits

```sh
python3 -I -B -m unittest -v
```

Run it from this directory. The tests use a stub `mlx.core` that writes real
safetensors headers with synthetic payloads. They cover the rename table for
both layouts, the transforms, the quantization policy, the head selection and
refusals, the `decision` block and its tokenizer check, the processor files
(byte-identical to the served pack's files for the served values), manifest
pin and tamper refusals, Hub snapshot identity, the receipt, key coverage and
the layout comparison.

The tests do not run MLX, quantize real tensors or execute the model. They do
not prove that `mx.quantize` output matches the served pack, that the
mlx-vlm transforms are complete for this checkpoint, or that the converted
pack gives the reference probabilities. The conformance run on the box
checks the layout and reports value equality. Decision accuracy needs a
separate forward-pass comparison.
