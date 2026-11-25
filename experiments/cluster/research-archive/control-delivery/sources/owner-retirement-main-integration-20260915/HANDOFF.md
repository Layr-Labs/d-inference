# Owner retirement shutdown integration

The exact reviewed OwnerService fix is promoted to MAIN. Its preimage
`67a597484dc15c1c9733e74efc8bc5ab449ff12730ce869058f907ef0150f7ae`
was checked before replacement with
`b23e811ae3c80de443c1e2c29c43c89c6283cefa74af68a431d1c5a9fc58120b`.
Existing files were untracked and retained in `backups`; unrelated MAIN files
were not changed. `final-integration.json` and `final.patch` describe exactly six
files: one runtime, the existing worker stand-in's exhausted mode, two regression
sources copied byte-for-byte from the frozen fixture, the existing SSH runner,
and its small README. `final/` contains the actual tested MAIN bytes.

A valid shutdown that was already in transit when an exhausted worker becomes
unavailable now preserves the owner release handshake. Session request/epoch/
sequence validation remains first. The owner neither sends to a closed child nor
synthesizes shutdownComplete or cleanup proof. Actual native termination, request
release, terminal publication and explicit owner release still gate journal clear.

The repository command is:

```sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
```

The final run passed in 18.637 seconds with empty stderr and all 44 actual MAIN
source/runner pins unchanged. It compiled the four Foundation modules and the
configured owner with Swift 6 warnings as errors and `-j 2`, passed the original
13 groups, and passed six retirement cases: late shutdown on both ranks with
actual cleanup/release and zero journals; active, duplicate and replay shutdown
refusal; and retained journal without explicit release. All observed owner test
processes exited. No model, native inference, remote call or network peer ran.
The compiler slot was released after terminal success.

`checks-1` preserves the first integration failure. The original repository
runner's TMPDIR expanded through `/var`, a symlink. The new real lease fixture
correctly refused that path before admission. `tmpdir-refusal-probe-1` repeats the
refusal with the prior frozen passing fixture binaries and retains actual owner
stderr. `corrections/tmpdir-refusal` changes only the runner's temporary root to
`/private/tmp`, which the existing lease tests already use. The product's path
validation and all assertions remain unchanged. `checks-2` is the successful
corrected run; the first proposal, receipts and backups remain historical.

The fix's separate source review and physical MTP retest belong to their own
frozen evidence. This integration claims repository CPU/control coverage, not
additional model, throughput or physical peer qualification.
