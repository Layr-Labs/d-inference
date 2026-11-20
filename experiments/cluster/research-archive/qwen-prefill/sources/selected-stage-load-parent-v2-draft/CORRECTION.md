# Exit during the final owned-process observation

V1 is preserved at `selected-stage-load-parent-draft`, manifest
`4f9c5c2cc7638614c3f21fb0afa8bad74d46d22bcd68d2287c6c6585a89f7c0c`.
Root observed a successful stage0 native process whose last `ps` sample still had
the exact owned PID/process group but printed `<defunct>` with RSS zero. The
original parent refused its live command check. Its failed receipt
`ee40c5255f62a812ae5593b81f8da40ac4c36c076d25f20d5bd410893b344876`
is retained unchanged. This source correction does not amend or reclassify that
receipt, and the author has not read its native stdout.

V2 recognizes only the exact `<defunct>` marker with integer RSS zero, exact owned
integer PID/PGID, and a fresh terminal result from that actual `Popen.poll()`
after obtaining the sample. The raw fields remain unchanged in the receipt. The
observed terminal exit code is retained and the accepted sample is explicitly
classified as an owned terminal observation, not live RSS. A cached claim from
the sample alone, another process, another command spelling, missing/nonzero RSS
or a child that `poll()` still reports running cannot take this path.

Natural exit code 1 or any other nonzero result remains a native failure. Free
memory, absolute reported swap, pressure, power, deadline, output, source/bundle,
metadata and cleanup checks are unchanged and still apply. Ordinary live command
and RSS identity checks are unchanged. No native command, resource threshold,
loader, source or tensor-audit scope changed. The V2 receipt namespace and explicit
exit-observation contract distinguish new runs from V1.

The original 21 fake tests are copied byte-for-byte. Ten additional fake test
methods cover this race, including exact post-sample poll ordering, nonzero exits,
wrong PID/PGID, near-marker strings, missing/nonzero RSS, malformed exit types,
running-child refusal, resources/power and the parent deadline. No actual native,
SSH, compiler, model payload, GPU or candidate stdout is used by these fixtures.
Use the same invocation in README with this V2 directory and a new output path.
