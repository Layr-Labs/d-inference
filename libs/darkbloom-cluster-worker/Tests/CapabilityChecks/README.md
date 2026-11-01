# Worker capability metadata checks

Run `./Tests/CapabilityChecks/run.sh` from the worker package. The runner builds only the actual Foundation/CryptoKit metadata source closure and the worker's metadata command/input helpers. It does not use SwiftPM, link MLX/Cmlx, build the native worker, open weights or execute GPU work.

The two fixtures are byte-exact configuration/manifest metadata decoded from the [historical registered-profile fixture](https://github.com/Layr-Labs/d-inference/blob/39ab57dc66da7d15dfeb4ba41fc4ceaf25e24433/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json) nine-model fields. Together they are 5,803 bytes; no tensor inventory or payload is copied. Configuration SHA is `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`; manifest SHA is `4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4`.

The pure producer must match the shared Protocol fixture's profile, four Plan/stage/construction identities and arithmetic receipt. Refusal cases exercise altered/oversized/unknown metadata, invalid binary binding, bounded regular-file reads, symlink/directory/FIFO refusal and exact command arguments. Five actual CPU fixture children exercise executable-file hashing and output; a wrong binary pin must fail before metadata files are opened. The installed executable in those tests is the CPU fixture itself, not the native worker.

The runner needs the sibling shared package and Python 3.9+. It has no dependency on a private research directory, external weights or a running service. All temporary build/input files are removed on exit. A full native worker metadata invocation remains a separate integration check.

The `registered-ternary-bonsai-2-9b` fixtures retain the exact configuration,
manifest, Hadamard metadata and safetensors header of the catalog's
`EigenLabs/Ternary-Bonsai-2-9B-MLX-2bit` revision `2026-10-15-base-r2` (aggregate
`3bfbed188a821cb7b16321b6be54245c6b162fc7d0ea064d5f663d0b07ee713d`). The header
SHA-256 is `3ac34a22f409632a5db6984373649c03a2ec463152a9d7965ce588df24ddc3e0`;
its source weight file is the manifest-pinned `model.safetensors` with SHA-256
`b8ebd13459dcd53504432a4a0a797287c3a4c00d80835466dbb499f05b7512bb`.
`Bonsai9Fixture` derives the 831 canonical text descriptors from that header,
excluding vision and separately verified transform signs. These files contain
no model weight payload; the runtime tests use lazy shells, not loaded weights.

The `registered-*.manifest.json` files of these models are the model CDN's
`manifest.json` bytes. The product's download keeps only a re-encoded receipt
(`.darkbloom-manifest.json`); the cluster store asks the CDN for the exact bytes
first and writes them beside the cloned files
(`ClusterProductModelStore.catalogManifest`). The coordinator's
`/v1/models/catalog/manifest/{id}` re-encoding carries each environment's own
`created_at`, so the runtime pins the CDN bytes. Fetched
2026-10-28T23:59Z to 2026-10-29T00:01Z (UTC) from
`https://models.darkbloom.ai/<r2_prefix>/manifest.json` (and `config.json`):

| Fixture | `r2_prefix` | SHA-256 |
|---|---|---|
| `registered-qwen35-35b-a3b.manifest.json` | `v2/qwen3.5-35b-a3b--f1f11460a4d1/2026-08-25-r1` | `1807c0cc834ac472a71013f6951ab82a620e7bc6b004a24866c9340d90dc5abb` |
| `registered-qwen36-35b-a3b.manifest.json` | `v2/qwen3.6-35b-a3b-vl-mtp-mxfp8--943d60189096/2026-08-11-r1` | `19a69c0c992dc4fda29d72f4f18a039865bccd8d9c6e0efe1104c4fa8b8b0ffc` |
| `registered-nemotron35-lightning.manifest.json` | `v2/nvidia-nemotron-3.5-lightning--ed925578dfaf/2026-09-30-r1` | `fd6491377ed831c22ccb168ce1cc71b003a3b9a0dccdcb53a08f31e8208cee78` |
| `registered-gpt-oss-20b.manifest.json` | `v2/gpt-oss-20b--ca1fe4e9c149/2026-05-25-r1` | `fe9f986d5574db34202ab32a16a99dd109b3233c904e87edc8cbfe40bc5a3461` |
| `registered-mimo-v26-flash-mopd.manifest.json` | `v2/mimo-v2.6-flash-mopd--3012243b1fbc/2026-09-28-r1` | `56c0a624037457a7e9705f765e50ff346c5fb4eec410bdfee443b20dbca56565` |
| `registered-gemma4-26b-qat-4bit.manifest.json` | `v2/gemma-4-26b-qat-4bit--69619d858022/2026-06-08-r1` | `e1bd0a99f0eeb451bd1be9baf700c7563816e3375bb24cdc6d1c8933cb36799e` |
| `registered-gemma4-26b.manifest.json` | `v2/gemma-4-26b--9e201d98f8d4/2026-05-25-r1` | `534b6e9eb9c4f93c24f12e191e022865388c124f8021c213852cc3c2d51f795c` |
| `registered-gemma4-26b-8bit.manifest.json` | `v2/gemma-4-26b-8bit--0402fbf4954e/2026-05-25-r1` | `84b34231bc57b36a2d412f2fb0608a7828437915806241ca212b30912ceabbbb` |
| `registered-glm53-flash.manifest.json` | `v2/glm-5.3-flash--0d8724178b09/2026-10-15-nvfp4-r1` | `ae8750273ae85bbcc9d77dfb3b8af8dd11bfb25622524689be2ee3a71bece570` |
| `registered-glm53-flash.configuration.json` (`config.json`, 10,023,646 bytes) | same | `949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b` |

The Qwen3.5 9B, Qwen3.8 27B and Ternary Bonsai manifests were already the CDN
bytes. The GLM files are metadata only; `check_command.py` describes them
through the actual `--describe-runtime` command, and
`provider-swift/Tests/ProviderCoreTests/Inference/Distributed/ClusterGLMManifestPinTests.swift`
describes them in the provider unit tests.
