# Exact native-key rejection fixture correction

Source-only successor to frozen prelude A `23fce2b6…f105afb`. It changes only
`Tests/NativeKeyChild.swift`; all nine proposed runtime files, the parent socket
cases, vector generator, helper and compile runner remain byte-exact.

The parent supplies a malformed binding and no later confirmation in three cases.
The previous generic rejection assertion could pass when a removed early guard
merely reached the 2.5-second socket deadline. The child now requires:

| Actual supplied fault | Required existing error |
| --- | --- |
| Replaced local public hello | `wrongContext` |
| Peer common epoch differs | `invalidBinding` |
| Low-order X25519 peer key | `invalidKey` |

The holder maps a later socket failure/deadline to `authenticationFailed`, which
matches none of these expectations. Successful establishment, any other error,
and any assertion failure exit the child nonzero. The parent still requires its
actual child exit 0 and exact PASS output. Deadline and reflection cases keep
their separate original assertions; no runtime taxonomy or timeout changes.

`integration.json` records the exact old/new fixture hashes. After a root slot
is granted, prepare a NEW combined source directory from A's 46 manifest members,
replace this one declared fixture after its preimage check, and write a combined
manifest with the same `files` structure. Run the unchanged `Tests/run.py` from
that fresh directory. Its ROOT-relative verification then binds the combined
source. Preserve both original frozen manifests and any build failures. Do not
modify the original A directory or execute its uncorrected fixture as qualification.

The planned 28 groups/35 actual local child cases remain unchanged. No compiler,
vector, child fixture, materialization, MAIN mutation or remote operation has run
for this correction. Source checks only verified all 46 original manifest members,
the single exact replacement and the unchanged nine runtime pins.
