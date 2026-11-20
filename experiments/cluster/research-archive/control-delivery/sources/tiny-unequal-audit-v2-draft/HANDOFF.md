# Tiny12 audit V2 handoff

Read `CORRECTION.md` for the source-order bug, preserved failure pins and explicit post-candidate-access chronology. `V1_HANDOFF.md` is retained historical documentation of the original prospective freeze; its chronology does not describe V2.

The API and entry are unchanged:

```sh
python3 -B tiny_unequal_audit.py SAVED_STDOUT
```

Only `tiny12_expected.py` changes among runtime audit sources: it sorts the expected loader receipt's inert-module list by path. The Plan's list and all numerical computations remain unchanged. `runtime-correction.diff` records the entire runtime delta. The same strict thirteen-record parser, original eleven-record prefix, full tiny12 metadata/identity checks, state/logit comparison and byte bounds remain in effect.

The thirty original invented CPU tests and four new source-order regressions pass. V2 test inputs contain no actual candidate logits or state payloads. Source copies under `source-correction/` come from the completed run's archive and are pinned; the exact source-derived sort is verified before the synthetic order tests.

V2 was written after authorized reading of the completed tiny candidate's failure and stage metadata. It is an explicitly documented expectation correction; it cannot claim to have been frozen before that candidate. The author did not replay the full V2 numerical audit on the actual candidate before freezing. Root owns that separate replay and its receipt. The original V1 freeze, failed audit and native launcher output stay unchanged.

The audit still does not qualify native source/binary provenance, resource/cleanup/stderr behavior, throughput, transport or target hardware. Those require separate root-owned checks. No native implementation, numerical tolerance, compiler invocation, GPU run or SSH action is part of this correction.
