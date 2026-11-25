# Isolated MTP loader native typecheck

The workspace copies current MAIN's four package/dependency trees, then applies
the unchanged nine-file MTP overlay (`e84353b2…653e6`). All source copies are
pinned. The original native-worker cache is an APFS clone; its relocated PCM
cache is preserved outside the active build directory. No source or cache in
MAIN is modified. The only symlink in the copied source is the original
relative `CLAUDE.md -> AGENTS.md` link inside Cmlx's MLX source.

The worker remains unchanged and cannot enable MTP. Building it typechecks the
new Runtime and MLXLLM code with the actual macOS 26.2 Cmlx/JACCL configuration,
and the existing build script checks the final Mach-O minimum and JACCL symbols.
The source-matched metallib is copied and pinned under `resources/`.

A separate private `MTPFactoryCheck` product exercises the new public SPI with
tiny fabricated CPU arrays. Its five groups cover complete ordered head reads,
unchanged target module identities, target/replica retention and release,
coverage refusal before reads, partial read failures, malformed callback data,
and a post-update cancellation check. It invokes no target/assistant forward,
allocates no request history and emits no tokens. It does not exercise the real
9B verified-descriptor materializer or establish MTP numerical correctness.

The fixture product and its explicit MLX dependencies are the only private
package-manifest changes beyond the frozen overlay. They are retained in
`records/factory-package.patch`; they are not a proposed serving product.

After the parent releases the compiler slot:

```sh
python3 build.py native-1
```

This performs the actual worker build, builds the tiny fixture, then runs that
fixture on explicit CPU streams with a 60-second process timeout. Exact logs,
commands, source/dependency checks and result pins are retained under the chosen
new directory. Jobs are fixed at two; automatic resolution and updates remain
disabled. Initial source review is independently recorded in
`qwen-resident-mtp-loading-review-20260915/source-review.json`.
