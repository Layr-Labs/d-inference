# Registered-member validation: complete Go fixture closure

Source-only successor to `cluster-registered-member-validation-20260916`
(manifest `6ee43bf2…6ea133`). The registered-member product overlay remains
`4ae431c6…ef965`; no Go/Swift product source or assertion changes. Frozen wrapper,
1091-file prepared workspace, dependency-download receipts and failed attempts
remain untouched. No materialization or compiler has run for this successor.

## Corrections

`fixture-inputs.json` explicitly pins five actual repository files and their test
readers. The existing preparation loop copies them at their unchanged repo-relative
paths into a new workspace; `verify_go` recomputes the source/fixture closure and
checks both original and copied bytes before/after the run. It rejects the old
1091-file snapshot. The new closure is 1096 files, with unchanged Go module/sum.

- `fixtures/prompt-contract/v1/production_vectors.json` is two levels above
  `coordinator/registry`, not under `coordinator/fixtures`.
- `deploy/gcp/prod/release-env-defaults`, `deploy/environments/prod.env` and
  `deploy/gcp/prod/required-env-keys.txt` are all consumed by the solo-seed tests.
- `scripts/install.sh` is compared byte-for-byte with the embedded API installer.

The first four bytes/hashes match the previously successful V2 registry closure.
The canonical installer currently matches the embedded installer. No file is
substituted with test-only data; no assertion is skipped or changed.

The expanded API suite reached its *package-wide* 120-second Go alarm after 779
API methods had passed, while the then-current test had run about one second.
Thirteen API tests remained incomplete. This does not establish a product
regression. Root authorized a wrapper-only `go-all` timeout of 180 seconds,
retaining the 300-second owned parent bound. Focused Go remains 120 seconds.
The actual failure stdout was 8,012,674 bytes, above the old 4 MiB parser cap.
Go now explicitly selects 16 MiB; Swift/copy helpers retain the original 4 MiB
default. The 512 MiB compiler-file ceiling and all native/model/request deadlines
remain unchanged. The owned process helper itself is byte-exact.

`prior-failure-analysis.json` binds raw evidence and separates missing-fixture
failures from the incomplete API timeout. `wrapper.patch` contains the narrow
four-file code/helper-lineage correction; `lineage.json` binds exact preimages.
The old wrapper's Swift materialization, filters, metallib binder review and all
product tests are otherwise unchanged.

## Root-run commands — only after a compiler/materialization grant

```sh
cd /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-validation-fixtures-20260916
/usr/bin/python3 -B prepare.py --phase go --output /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-build-2-20260916
/usr/bin/python3 -B run.py --phase go-focused --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-build-2-20260916 --attempt 1
/usr/bin/python3 -B run.py --phase go-all --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-build-2-20260916 --attempt 1
```

Run sequentially; preserve every result. Offline Go1.25/race/jobs2 and exact
source/tool hashes remain. No dependency download is added. A passing run must
still complete all three selected packages, all15 verified-pair methods and all4
member-role methods; full mode keeps every original API/registry/protocol test.
No coordinator deployment, model, native or remote operation is authorized here.
Swift qualification remains pending its separately coordinated slot.
