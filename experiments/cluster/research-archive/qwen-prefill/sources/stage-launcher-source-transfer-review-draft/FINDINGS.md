# Source-transfer compatibility review

2026-09-14; read-only local source/Git metadata and installed Git manual review.
No remote action, clone, bundle creation, repository content edit or native job.

Independent repositories cloned at the existing gitlink paths are compatible
with the public archive. Embedded `.git` directories are a supported Git layout;
`absorbgitdirs` is not required by the launcher. Register the submodules using
local-only `git submodule init` in the root repository and `libs/mlx-swift` after
placing the clones. Do not rely on merely having directories: uninitialized
status can be `-`, and foreach may skip an unregistered checkout. No network
update is needed once each exact commit is locally cloned and checked out.

The current local gitlinks and checked-out commits agree:

| Path from root | Commit |
| --- | --- |
| `libs/mlx` | `3fa8f25e6451174d7b06be372c3a24272b77d88e` |
| `libs/mlx-swift` | `6d6796d7a81b656d2749d39067e0a6bea2bc2986` |
| `libs/mlx-swift/Source/Cmlx/mlx` | `3fa8f25e6451174d7b06be372c3a24272b77d88e` |
| `libs/mlx-swift/Source/Cmlx/mlx-c` | `02cf6f4d099023e4e0c0357248b8b3f83110e29d` |
| `libs/mlx-swift-lm` | `ce446cc5f76e013855fe0bde9002b6db1ac091b7` |

Root HEAD is `e4df336bc8399f4fd0a46d1207b594d2514f14f5`. For empty destinations,
bundles must be self-contained; use a named ref such as HEAD rather than only
a literal commit SHA as the bundle revision. Explicitly check out each intended
commit after cloning. Confirm exactly five recursive status entries, each with
a blank prefix, plus empty output from the exact runtime command:
`git submodule foreach --recursive --quiet 'git status --porcelain --untracked-files=no'`.
The current local command is empty. A recursive count check is useful because
the current archive does not itself reject a missing/uninitialized submodule
count; it records Git’s status string and requires stability across the run.

`submodule status` also includes git-describe labels. HEAD-only bundles may omit
local branch/tag names and therefore change those parenthesized descriptions.
Preserve the remote description honestly. `archive.dependency_identity` compares
that remote identity before/after one run; it does not require byte equality to
the build Mac’s status text. Compare the actual paths and commit IDs to the
supplied build-source identity instead of rewriting descriptions.

The public archive deliberately permits dirty root experiments while rejecting
tracked dependency changes. A Git bundle does not include the dirty/untracked
working tree. Apply the final integrated experiments source overlay using an
explicit pinned file inventory, including newly added modules and any deletions;
then compare the same inventory remotely. The current tracked experiments diff
contains no deleted files, but that is not a substitute for the final inventory.
Do not touch dependency source trees or their manifests with the overlay. Keep
build/generated state excluded; transfer the matching release executable,
metallib and resources separately with their pins/build receipt. Root HEAD plus
exact experiment hashes is the truthful identity, not a claim that HEAD alone
built the transferred executable.

Finish public patch integration before the final overlay/source inventory, and
hold both source trees stable while the public launcher runs. Its archive hashes
runtime Markdown as well as Python/Swift, so edits to included documentation can
still fail a completed cohort’s source recheck. No runtime guard needs relaxing
for this transfer path. Actual remote initialization and checks remain root-owned.
