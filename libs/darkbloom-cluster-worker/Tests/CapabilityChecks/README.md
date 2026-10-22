# Worker capability metadata checks

Run `./Tests/CapabilityChecks/run.sh` from the worker package. The runner builds only the actual Foundation/CryptoKit metadata source closure and the worker's metadata command/input helpers. It does not use SwiftPM, link MLX/Cmlx, build the native worker, open weights or execute GPU work.

The two fixtures are byte-exact configuration/manifest metadata decoded from the [historical registered-profile fixture](https://github.com/Layr-Labs/d-inference/blob/39ab57dc66da7d15dfeb4ba41fc4ceaf25e24433/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json) nine-model fields. Together they are 5,803 bytes; no tensor inventory or payload is copied. Configuration SHA is `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`; manifest SHA is `4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4`.

The pure producer must match the shared Protocol fixture's profile, four Plan/stage/construction identities and arithmetic receipt. Refusal cases exercise altered/oversized/unknown metadata, invalid binary binding, bounded regular-file reads, symlink/directory/FIFO refusal and exact command arguments. Five actual CPU fixture children exercise executable-file hashing and output; a wrong binary pin must fail before metadata files are opened. The installed executable in those tests is the CPU fixture itself, not the native worker.

The runner needs the sibling shared package and Python 3.9+. It has no dependency on a private research directory, external weights or a running service. All temporary build/input files are removed on exit. A full native worker metadata invocation remains a separate integration check.
