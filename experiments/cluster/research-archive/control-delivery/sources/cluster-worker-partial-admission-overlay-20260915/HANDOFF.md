# Partial admission cleanup correction

Ready for root review/promotion. The only runtime change is `ClusterWorkerRequest.swift`. `integration.json` maps that file, the four-case `PartialAdmissionTests.swift`, and its appended ProcessChecks runner invocation. Main and the prior frozen qualification package were not edited.

The defect occurred when rank 0 failed during sequential admission before rank 1 received a reservation. The old cleanup loop sent request cancel to both ranks. Rank 1 correctly rejected a command without a current request; its owner fenced native work but left a sticky journal after the protocol failure.

The request now records each rank as none, submitted, admitted, or explicitly refused. Submission is recorded only after the existing bounded enqueue succeeds, under the same request lock as cancellation. A matching refusal is recorded separately because it clears the native request. Only confirmed admission authorizes request cancel during cleanup. Never-submitted, pending, or refused ranks receive endpoint native-cleanup requests instead. Pending submission also needs fencing because an unread refusal may already have cleared the native request.

The existing cleanup loops still wait for actual native cleanup proof on fenced ranks. Reservation ceilings/charges, exactly-once release, deadlines, independent cancellation watchdog, worker command counters, and Service/session validation are unchanged. Endpoint fencing does not consume a native request command sequence or constitute cleanup proof. A withheld proof keeps failed admission blocked and the pair unavailable.

Validation, all Foundation CPU only with Swift 6 warnings-as-errors:

- Existing Process10 groups, provider contract, four deadline children, and two endpoint groups passed in the 28.676-second public runner. That execution also passed the initial three partial-admission cases.
- Final four focused cases passed in 1.498 seconds: first-rank refusal, second-rank refusal, pending admission timeout, and missing native proof during pending/never-submitted cleanup. The last case observes actual child exit while withholding endpoint proof, requires admission not to return, then supplies proof and requires completion.
- Existing SSH owner suite passed all 13 local-child groups in 17.057 seconds. No real SSH was used.
- The real configured-owner/argv-compatible stand-in fixture passed both cases in 2.073 seconds. Output2 returns `[9,10]`; output3 still fails before first-rank admission. **Both** cases now observe both native cleanups, both authenticated lease release ACKs, and two zero-size journals. Raw result records and the retained temporary directory are in `records/configured-check-run.stdout`.

The stand-in executable and parser-only Runtime library are copied unchanged from frozen `owner-ssh-qualification-20260915/build-v3`. The configured-owner executable and Protocol/Process/Remote/Bootstrap libraries are built from the isolated current-main source snapshot plus this correction. All unmodified snapshot inputs are checked in `records/source-check.json`. Existing failure evidence in the earlier qualification folder remains historical and untouched.

`runtime.patch` contains only the runtime correction; `integration.patch` also includes the public test and runner. Root can apply the three-file map after its current source-pinned build completes. No native MLX, models, GPU, network, deployment, or external timing work occurred here.
