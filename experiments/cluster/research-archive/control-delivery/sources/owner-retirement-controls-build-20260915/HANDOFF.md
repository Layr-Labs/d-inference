# Portable owner controls with retirement-aware shutdown

The portable Foundation build passed in4.367seconds with empty stderr and all43
source/runner pins unchanged. It compiles the fixed36-source module closure from
`cluster-owner-retirement-shutdown-draft-20260915` manifest
`072f18aad68445809a35896f1c8731febd1783f02f5b1261ddba946e1344febf`.
The single service fix is SHA
`b23e811ae3c80de443c1e2c29c43c89c6283cefa74af68a431d1c5a9fc58120b`.
No MAIN, native-worker source/binary, remote machine or model was changed.

Two six-file bundles share the same normal controller and four newly linked
Foundation libraries. Each retains its existing configured-owner entry source:

- `bundle-mtp`: the prior wakeup entry, whose existing cut4/8/12/16 scope supports
  the pinned9B MTP configuration. No new model/cut admission was added.
- `bundle-qwen27b`: the existing strict registered27B/cut32 entry and scope helper.

Use a complete bundle. Each contains `owner-controller`,
`darkbloom-owner-qualification`, and Protocol/Bootstrap/Process/Remote dylibs. The
controller is local; the scoped owner and its four dylibs go together on each
host. Rank-specific trusted `owner.json` must remain adjacent to the owner.
Native binaries are deliberately absent: retain exact MTP `34fcd255...` or27B
`a7c35b37...` and their matched resources, with explicit fresh configuration.
Do not combine new libraries with old compiled controllers/owners.

Bundle manifest pins:

- MTP: `9dfda2faebdf63293ab5126d9c6ee63aecd5fe6b09cd5952a6cae538500d5bd7`
-27B: `5c3128ca29367e3b5a8ae4552fb2f45b15d230c2557bba572d9634bd0f0c1aac`

The common controller is `13311eeac86a019a7c187249fbe7393471e9e158821f5eaa8d5637f392851a74`;
the fixed Remote library is `d7f29a4878504481534a9c631be83dce83445324826082be57a9ae43dc309ef1`.
`source-lineage.json` binds all entry copies and module sources. `portable-linkage.json`
retains otool/vtool inspections for every bundled artifact: macOS14.0 minimum,
only system or @rpath imports, and @loader_path/@executable_path plus the
toolchain's `/usr/lib/swift` system search path. The initial overly strict rpath
inspection refusal is retained in `linkage-check-1.json`; no source/build changed.

These production-mode modules were freshly linked from the same reviewed source
as the passing CPU regression. This handoff claims compilation/linkage, not a
new actual-machine or exact-production-binary lifecycle execution. Root reviews,
deploys/verifies the complete trees, and performs the fresh MTP and27B checks.
The old physical failure, missing acknowledgments and sticky journals remain
unchanged. Administrative recovery is a separate, explicitly reviewed action;
neither elapsed time nor this new binary fabricates the missing prior release ACK.

Root has the one-file integration patch for eventual MAIN promotion. Arithmetic
is preparing the fresh MTP epoch/configuration/parent using `bundle-mtp`; the27B
parent is checkpointed pending the recovery and actual clean MTP release test.
