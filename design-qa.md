# Darkbloom Welcome Motion Design QA

## Comparison target

- Source visual truth: `/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/TemporaryItems/NSIRD_screencaptureui_26SPem/Screenshot 2026-07-15 at 4.03.09 PM.png`
- Implementation frames: `/tmp/darkbloom-wave-0.png`, `/tmp/darkbloom-wave-6.png`, `/tmp/darkbloom-wave-12.png`, `/tmp/darkbloom-wave-18.png`, and `/tmp/darkbloom-wave-24.png`
- Viewport: native macOS window at 1040 × 680 points; implementation captures are 2080 × 1360 Retina pixels.
- State: welcome screen, front-facing machine card, idle field. A focused back-card capture is at `/tmp/darkbloom-wave-back.png`.

## Comparison evidence

- Full-view source + five-time implementation contact sheet: `/tmp/darkbloom-wave-motion-comparison-v1.png`
- Focused source + implementation field at t=0, t=12, and t=24 seconds: `/tmp/darkbloom-wave-focused-comparison-v1.png`
- The focused comparison was required because the motion geometry around the machine card was too small to judge reliably in the full-window sheet.

## Findings

- P0: none.
- P1: none.
- P2: none after the motion iteration below.
- P3: an Animation Hitches trace was attempted, but the local logging archive was corrupt or incomplete and Instruments could not produce valid metrics. The app still built, launched, and rendered all deterministic frames successfully; this remains a performance-measurement gap rather than a visual or functional defect.

## Required fidelity surfaces

- Fonts and typography: unchanged from the approved Chivo composition; no new wrapping, hierarchy, or antialiasing drift appeared.
- Spacing and layout rhythm: the wordmark, copy, controls, machine card, radii, and shadows remain fixed while only the background field moves.
- Colors and visual tokens: the white canvas, pale blue, mist, cobalt, and deep cobalt constants are unchanged. Motion changes geometry, not palette or overall contrast.
- Image and effect fidelity: the field remains a native Metal effect with clean full-height edges and no raster scaling, seams, rectangular plate, or compression artifact.
- Copy and content: unchanged from the approved welcome screen.

## Motion review

- The broad color mass drifts on independent 20–60 second cycles.
- Three visible ribbons use different spatial directions and 15–40 second traveling phases, so they flex locally instead of moving as one concentric ring.
- The luminous centerline meanders independently while remaining anchored to the machine card.
- Card focus adds a low-amplitude, distance-decayed pressure ripple; setup hover increases deformation amplitude without changing absolute phase.
- Idle rendering uses 30 fps for efficiency; card or setup interaction uses 60 fps.
- Reduce Motion and deterministic preview capture freeze the field. Card parallax and outer flip springs are also suppressed under Reduce Motion.
- Every welcome phase is an integer harmonic of the 120-second master loop. The t=0 and t=120 captures measured 102.43 dB average PSNR, confirming a visually seamless wrap.
- The t=0→t=1 comparison measured 43.45 dB average PSNR and t=0→t=2 measured 38.16 dB, confirming visible continuous change at normal viewing cadence without a sudden wipe.
- The original launch bloom remains on its isolated shader branch; its post-change capture is `/tmp/darkbloom-launch-wave-pass.png`.

## Comparison history

### Iteration 0 — blocked

- [P2] The three pale bands were fixed iso-contours of one slowly moving Gaussian field. They behaved like rigid concentric rings and appeared nearly static in the user’s screenshot.
- [P2] Center motion ran on roughly 90–250 second cycles, and hover activity multiplied absolute time, creating a potential phase jump rather than a natural increase in energy.

### Fix applied

- Replaced the single shared motion phase with a loop-safe 120-second master clock and independent integer harmonics.
- Added two-dimensional domain advection, independently traveling fold levels, subtle fold relief, aperture breathing, and a card-responsive ripple.
- Changed activity from a speed multiplier to a deformation-amplitude control.
- Added deterministic preview-time control so multiple points in the real shader cycle could be compared.
- Preserved the original launch branch and exact approved palette.

### Post-fix evidence — passed

- `/tmp/darkbloom-wave-motion-comparison-v1.png` shows materially different but compositionally stable field geometry at t=0, 6, 12, 18, and 24 seconds.
- `/tmp/darkbloom-wave-focused-comparison-v1.png` shows that the ribbons bend and pass the card at different rates and directions rather than translating as one outline.
- No actionable P0, P1, or P2 visual differences remain.

## Verification

- `./script/build_and_run.sh --verify` — passed, including Metal compilation and app process verification.
- `swift test --package-path provider-swift --filter DarkbloomAppTests` — 4 tests passed.
- `git diff --check` — passed.

final result: passed
