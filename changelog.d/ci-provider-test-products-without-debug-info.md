### Provider CI: provider test products built without debug info

- The provider lane builds its test products with `-debug-info-format none`, so the build emits no DWARF and runs no `dsymutil`. No DWARF reached a test job before either: the products archive already drops the object files and `.dSYM` bundles. Test results, failure and crash messages, stalled-test samples and the coverage report are unchanged.
- The provider lane's Swift build cache entries share no restore tier with builds made with DWARF (`scripts/provider-ci-cache.py`), which SwiftPM would recompile in full.
