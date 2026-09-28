# Public constructor-probe support

This package adds the public runner and API/run document plus README and
`docs/developer/test.md` insertion proposals. It changes no core source.

After integrating the frozen constructor source package, place its two fixture
files `ConstructorProbeCheck.swift` and `ConstructorProbeCheckMain.swift` directly
under `experiments/cluster/inference/Tests/ConstructorProbes/` once. This package
intentionally does not duplicate them. Copy the proposed `run.sh` and document,
then apply the two documentation insertions against the current root-owned tree.

`source-map.json` maps the exact ordered 15 compilation inputs back to the frozen
constructor source list. The runner reads the existing shared retained input;
no second metadata file or new model input format is introduced. Its optional
source-directory override follows the other public Foundation harnesses.

The author ran shell syntax and source/path/link checks only. Root owns all
Swift compilation, fixture execution and independently guarded native runs.
Root reports the standalone15-source fixture passed11/41. The source check also
verified all15 integrated production/fixture bytes against the frozen inputs.
The public runner has not been executed, and native constructor results remain
explicitly pending in the prose.
