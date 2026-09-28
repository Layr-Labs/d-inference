# Private 27B cut16 correctness candidate

Ready for root review and sequential copy/preflight/physical execution. No remote operation or candidate output read occurred here. The expected agreement and comparator policy were prepared before the new reference was read; the matching reference has now passed a separate CPU-only validation. All prior cut32 failures, source packages and remote trees remain unchanged.

## Exact binding

- New remote root on both Macs: `/Users/developer/DarkbloomDev/qwen27b-cut16-owner-validation-20260915`.
- Fresh membership epoch `c118a4a7-9bde-4a61-954c-4e4586f7c091`; original cluster ID retained. Request UUID `20801ced-ca29-4faf-b71a-9ebbe1886a14`, exact32 tokenizer-derived IDs, C16/O128, empty stops, serial and MTP-off remain.
- Native989f and both matched resources are unchanged from the diagnostic candidate. The private owner is `6f6c2164b692f1011b648ba81fbaa0974c92a1fba3d1316b73e1e2761f8ed3ba`: the sole source delta from da554 is the qualification cut constant32→16. Main, diagnostic writer, native argv construction, bootstrap and lease/service behavior remain exact. Its four remote dylibs are unchanged. Local draining controller862f and its coherent four modules remain unchanged.
- Actual Foundation owner relink, metadata compile and model-free metadata invocation passed in0.434/1.662/0.501s; all68 pins unchanged, empty stderr, exit0/reaped/group absent. Owner linkage remains macOS14.0 with system and four`@rpath` dependencies. No owner/native/model execution was used for these checks.
- Actual cut16 Plan `8e1408f4f044b0fa6f97ae9b997d575797fe1d22036ddb68409e2aeb349949ed`; stages792c7df3…b219/b43375c3…0271. Counts463/1384 and active bytes4,140,778,752/10,992,023,296. Both Ready templates bind this Plan and native989f; zero epoch/capacity1 are still codec placeholders, never readiness or capacity claims.
- Request raw SHA3b9ca1f7…0a4f changes only explicit cut/JSON encoding relative to the old packet. Tokenizer/source provenance and the semantic generation request fingerprint are unchanged.
- Expected storage `092458153610edef1a62703fc87364fce6aad11b4c064c03d521e8745d19be64`, arithmetic0ae9c7…3bc74. The source-qualified storage calculation replays the entire prior cut32 commitment and1,847 mappings before deriving cut16; it does not claim a cut16 constructor or loaded-array observation.
- Actual corrected preparer PASS; expected agreement `42c310634e03957f611a2c827347f1faf3d6bcc06003296b6c398932b4b56b2e`. Relative to the preceding diagnostic agreement, only epoch, Plan, stage fingerprints and storage commitment change. Rank build IDs, request/profile fingerprints and arithmetic remain exact.

## Root-only sequence

Use the exact arrays in `commands.json`, sequentially from this directory:

```sh
/usr/bin/python3 -B check_source.py --artifacts
/usr/bin/python3 -B deploy_copy_only.py --rank 0
/usr/bin/python3 -B deploy_copy_only.py --rank 1
# Root performs separately authorized purge/resource preparation.
/usr/bin/python3 -B preflight.py --rank 0
/usr/bin/python3 -B preflight.py --rank 1
/usr/bin/python3 -B run_physical.py
```

Copy wrapper, owned-child helper and11 supporting scripts are exact copies of the reviewed preceding package. Run/preflight/installer differ only in the new root. Each remote tree has exactly14 files: new owner, four unchanged remote dylibs, unchanged native/resources, complete monitor closure, matrix and cut16 owner config. Modes remain700 executables/directories and600 other files. Copy uses pinned SSH trust and`-S none`, refuses existing roots, fully rehashes its closed inventory and launches nothing. A copy failure or timeout remains an unresolved outcome; inspect/retain the partial tree, never overwrite or retry blindly.

Preflight fully checks files, modes, directories, no active owner/native, empty evidence and the canonical empty journal under its existing flock. Native initial free-memory requirements are9,727,600,687/16,602,658,967 bytes; these are not whole-load or Ready guarantees. All existing actual-free/allocator/resource guards remain. The native reports exact refusal operands if another phase fails.

The physical parent retains the original300s owner lifetime,315s local controller bound, bounded actual postflight and alias restoration. Native cleanup, authenticated release ACK, diagnostic EOF, transport termination, process absence and journal emptiness remain separate evidence. No cleanup or journal policy was weakened to admit this cut.

## Reference and numerical gate

Frozen prospective comparator: `qwen27b-cut16-numerical-audit-20260915/manifest.json`, SHA`f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe`. Nine numerical runtime/helper files are exact; only one catalog entry is added from actual metadata. Five fabricated CPU methods pass, including oldcut32 byte parity,36/108 rank state ownership and explicit refusal of a cut32 reference under cut16.

Matching actual d717 reference raw stdout is `qwen27b-cut16-full-reference-20260915/physical-collect-1/returned/native/worker-0.stdout`, SHA`539f0ed31bf4b95590d26df3468b2d3863520bc742d2c62cd37bcb8ca94d6e26`. `reference-only-check.json` records an actual CPU validation under the frozen cut16 policy:128 IDs,129 frames/frontier159, final496,640 BF16 bytes and144 state entries. This is not a candidate comparison or an independent physical cleanup attestation. `verify_reference.py` and the exact repeat command are in `commands.json`; its output must be a new path.

After root retrieves successful candidate sidecars, use the unchanged six-role packet interface and frozen `audit_generation.py`: registered request, registered Plan metadata, prompt, reference stdout, rank0 evidence, rank1 evidence, plus this exact expected agreement. Full comparison checks selected IDs, sequence/final frontier, reconstructed final BF16 row and complete global state metadata/digests. Opaque non-offset state hashes, absence of per-token candidate logits and unverified intermediate native frontiers remain explicit limits. No external TTFT, sustained throughput, product eligibility or physical cleanup follows from that comparator.

`source-checks-2.json` records source/config inverses plus full artifact rehash. `manifest.json` pins this local package; `run-pins.json` additionally binds binaries, modules, source/provenance and the frozen comparator. Source checks are prospective and precede copy/preflight/physical directories. No full binary hash, compiler, bulk copy or remote work overlapped root's reference physical window.
