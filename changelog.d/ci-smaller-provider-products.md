### Provider CI: smaller test products hand-off

- The test products archive leaves out what no test step reads: every `.dSYM` bundle (the test bundle's own included), the host tools (the `-tool` macro and `Modules-tool`) and SwiftPM's bare clones in `.build/repositories`. The coverage report reads the coverage maps in the binaries, not DWARF, so it does not change. A stalled-test sample now names each frame's function and offset, but not its file and line.
- zstd packs the archive at level 9 with a 2 GiB long-distance window, which stores repeated content such as the test bundle's metallib copies once. On the provider products of run 42318853015 the archive goes from 1,065 to 265 MiB. Unpacking needs the same window and about 2 GiB of memory.
- The pack step also prints the size of the archived files.
