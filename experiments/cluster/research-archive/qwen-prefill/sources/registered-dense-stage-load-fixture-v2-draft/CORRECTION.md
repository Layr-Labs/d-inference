# Selected-stage fixture compiler correction

2026-09-14. Frozen V1 remains unchanged (manifest `a9b31d48785226b75ba684a96c4e916d229bfe7bcc4b25f2c88d33150e9db244`). Root's first Swift 6 warnings-as-errors compile rejected the fixture because the fake-read guard in the catch branch was provably always true. The failed compile and stderr were retained by root; neither Swift tests nor native materialization ran.

V2 removes only that vacuous counter and guard. The rejection helper now returns from catch and otherwise throws the existing unexpected-acceptance error. All production sources, case bodies, result fields, and the 21 accepted/122 rejected assertions are unchanged. `fixture-source-list.json` replaces exactly the V1 fixture path/hash/size; the other 29 source records and shared retained input are identical.

This also supersedes the V1 HANDOFF's fake-read-counter description. These checks exercise actual pure admission predicates. They provide no independent production payload ordering, private gate poisoning, partial materialization or cleanup coverage. Root owns compilation and execution of this corrected fixture.
