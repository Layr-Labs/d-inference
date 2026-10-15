The existing Swift child passed 78 tests in 12 suites. Its wrapper then refused the valid Swift Testing parameterized completion grammar. This package corrects only result parsing and supplies an additive qualification plus a CLI-only build gate. It does not copy, prepare, edit or rebuild a source tree during qualification.

The parser requires one parent start, one `acknowledge → false` start, one `acknowledge → true` start, and one exact `with 2 test cases passed after <numeric duration> seconds.` completion, with both cases between the parent start and aggregate completion. Swift Testing reports that aggregate only after both cases complete; it does not emit separate case pass lines. Any extra title-bearing record, wrong count, missing case, duplicate, start-only output or `✘` issue/failure refuses. All ten named member/CLI methods and both B protocol methods must still have one actual pass line. Qualification additionally checks all 78 unique aggregate test completions and 12 unique suite completions against the exact summary.

`raw-inputs.json` pins the actual natural exit-0/reaped/group-absent child, stdout/stderr, preparation, both full source maps, and its immediate unchanged-source postflight. Qualification reconstructs the retained source map using the exact member+B+two-await composition and verifies frozen source inputs. It records that the current whole trees were not rehashed during this parser-only step. The CLI gate performs the inherited full current MAIN and candidate source/dependency inventories before and after its single owned build.

Run the additive qualification (no compiler or child process):

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-member-swift-result-correction-20260916/qualify.py --attempt 1
```

After root grants the compiler slot, use the returned exact checks SHA256:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-member-swift-result-correction-20260916/build_cli.py --qualification /Users/developer/DarkbloomDev/cluster-research/cluster-member-swift-result-correction-20260916/qualification-1/checks.json --qualification-sha256 CHECKS_SHA256 --attempt 1
```

The only launched command is the original `swift build -j 2 --disable-automatic-resolution --disable-build-manifest-caching --product darkbloom`, in the unchanged absolute candidate workspace. It retains the original 900-second owned helper, 4 MiB diagnostic cap and 512 MiB file ceiling. Outputs are create-only under `actor-await-correction-1/swift-build-corrected-parser-1`. No tests are rerun, binary executed, native grant enabled, model loaded or remote contacted. The old wrapper, source corrections, failed compile, parser refusal and actual successful-child evidence remain unchanged.

Modularity: `corrected_results.py` owns grammar; `qualification.py` owns retained-run proof; `context.py` reuses the exact frozen source/owned helpers; `qualify.py` and `build_cli.py` are thin entry points. No product source or test assertion changes.
