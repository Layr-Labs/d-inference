# Root-owned local qualification sequence

Every step after the source checker requires a separately scheduled root slot. Commands are in `commands.json`; they are not automatic.

1. `python3 -B check_source.py` reads only small pinned sources/metadata and parses Python.
2. `python3 -B Build/check_cpu.py 1` builds/runs the Foundation checks sequentially (90-second compiles, 30-second runs, jobs2), the actual host-budget printer, and 12 Python methods. No MLX import or model worker in this step. Preserve `Build/cpu-1` on any failure.
3. `python3 -B Build/prepare.py` owns a 120-second preparation child. It checks all3050 sources and8755 dependencies, preserves exact old cache binary6495 with one APFS clone, saves allpreimages, applies only15 overlays, and writes exact new3053/8755 snapshots. No whole-cache clone or reset. Failed/partial preparation refuses automatic retry.
4. `python3 -B Build/build_native.py 1` uses the existing build-native-worker.sh/cache, jobs2 and900s; vtool/otool each10s. It rechecks the full prepared source/dependency closure and wrapper pins before/after. Native resource hashes remain2129mlx/4ad3paged.
5. `python3 -B Build/package_native.py 1` creates the new three-file runtime bundle only after actual build success. `python3 -B Build/check_arguments.py 1` runs only clock and invalid-path argument controls (15s each), with cut16 accepted/cut32 refused. It does not connect a bootstrap socket or load a model.

The retained phase workspace is `/Users/developer/DarkbloomDev/cluster-research/resident-generation-phase-native-draft-20260916/Build/workspace`; reusing it is an explicit private mutation. The old frozen source copies/manifests/snapshots/bundle/evidence remain unchanged, and the old build-cache binary is separately retained before mutation. Current MAIN is never a source substitute or mutation target. Any stale source, dependency, resolver, native resource or old binary must refuse; no blanket acceptance is provided.

The generated reference and candidate run helpers are separate later physical actions described in `ROOT-STEPS.md`. No compiler, bulk copy or competing native work may overlap those scheduled physical windows.
