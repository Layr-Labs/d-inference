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
