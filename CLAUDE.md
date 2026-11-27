# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Posture** is a native macOS menu-bar app (macOS 14+, Apple silicon). It tracks head posture from the AirPods motion sensors (`CMHeadphoneMotionManager`) and shows your status and numbers in a panel around the MacBook notch. It alerts after sustained slouching. It's AirPods-only by design: no camera, no Apple Watch, no network. An iOS version and a 3D head/bust visualization both existed and were removed at the user's request (the bust felt creepy and didn't reflect real posture), so don't re-add either.

## Commands

```sh
./build.sh                 # compile Sources/Core + Sources/App with swiftc → build/Posture.app (ad-hoc signed)
open build/Posture.app     # run (it's an LSUIElement menu-bar app; `pkill -x Posture` before relaunching)
./test.sh                  # compile + run the whole test suite (exit code 1 on failure)
open Posture.xcodeproj     # optional: run/debug in Xcode (schemes: Posture, PostureTests)
```

- **Two build paths, same sources:** the scripts (plain `swiftc -swift-version 5`, no SwiftPM) and `Posture.xcodeproj` (for running/debugging in Xcode). The Xcode project uses synchronized folders (`Sources/Core`, `Sources/App`, `Tests`; subfolders included), so new files need no project edits; the PostureTests target compiles `Sources/Core` + `Tests` only, and is built with `-O` even in Debug (unoptimized it takes over 10 minutes). Keep both paths building. The scripts: Both scripts source `scripts/toolchain.sh`, which falls back to the Command Line Tools if Xcode is unusable (license not accepted) and builds for the host CPU; `UNIVERSAL=1 ./build.sh` builds arm64 + x86_64, `ARCHS=x86_64` picks one. Minimum macOS is `MACOS_MIN` there (keep it in sync with `LSMinimumSystemVersion`).
- **Layout and adding files:** `Sources/Core/<Area>/` (Motion, Calibration, Posture, Hunch, Alerts) holds everything the tests compile; `Sources/App/` holds the app shell: `PostureApp.swift` (`@main`), `PostureMonitor.swift` (AppKit/ServiceManagement, so never test-compiled) and `Views/`. Both scripts glob recursively (`Sources/Core/**/*.swift`), so a new file anywhere under those folders needs no script or project edits. Code that must be tested goes in `Core`, never in `App`.
- **Tests:** a custom harness, not XCTest (`Tests/TestSupport.swift`: `test(...)`, `expect`, `expectNear`). `Tests/main.swift` calls each group function (`estimatorTests()`, `dingTests()`, …). There's no per-test filter. To run one group, temporarily call only that function in `main.swift`. Add a new test group by writing a `func xxxTests()` and calling it from `main.swift`.
- **No macros:** the Command Line Tools toolchain lacks the SwiftUI macro plugins, so `@State` / `@Observable` fail to compile there. Use `ObservableObject` + `@Published`, `@StateObject`, `@AppStorage` (property wrappers, not macros).
- **Must build with Swift 6.2 (macOS 26 / Xcode 26) as well as newer compilers.** 6.2 gives up ("unable to type-check this expression in reasonable time") on long expressions that mix literals, `.pi` and SIMD/matrix math, and can't resolve `simd_double3x3 * Double` (use `scaled(_:by:)`). Write such math as short steps with explicit types (`let x: Float = …`, `SIMD3<Float>(…)`), avoid long `map/filter/reduce` chains, and prefer per-component scaling to `SIMD3(...) * (a * b)`. `./test.sh` fails on any expression over 50 ms. To check against 6.2 itself: unpack the swift.org 6.2.x toolchain and run `PATH=<toolchain>/usr/bin:$PATH SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ./test.sh`.

## Architecture

### Signal pipeline (in `Sources/Core`, driven by `Sources/App/PostureMonitor.swift`)

`HeadphoneMotion` (~25 Hz) → `SpikeFilter` → `LeverArmCompensator` → three consumers:

1. **`PostureEstimator`:** head tilt (pitch/roll relative to the calibrated head frame, from gravity) plus head *position* (forward/down cm). Position = neck kinematics + a per-axis `ZUPTKalman` (position, velocity, accel bias) with zero-velocity updates when `StillnessDetector` says still.
2. **`RelativePositionTracker` (display only):** world-frame "Moved ↑/↔" readout. **Never** used for posture decisions.
3. **A second `RelativePositionTracker` + `DeskModeDetector`:** sitting/standing detection.

`PostureMonitor.tick()` (1 Hz) turns `reading` into reasons:
- `PostureRules` (forward tilt, side tilt, head shift; separate limits for sitting/standing). `assess` splits reasons into **body** (real head movement `forwardMoveCM`/`dropMoveCM`, side tilt: count at once) and **looking down** (head only tipped forward, which a keyboard glance also does: count only after `LookDownGrace`, default 30 s).
- `HunchDetector` (+ personal `HunchClassifier`, smoothed by `HunchStateFilter`).

The reasons feed `SlouchTimer` (10-min alert) and `SlouchDingRule` (gentle ding), which in turn drive `Notifier` and `Chime`.

### Calibration (`Sources/Core/Calibration`)

`CalibrationSession` owns the whole sequence (steps, recording, early finish, slouch test, notes); `PostureMonitor` only supplies the step timer, motion samples and UI.

Steps: sit tall → look down → *(optional slouch test: slouch, sit tall again)* → turn → tilt. Neutral is the **latest steady 1.5 s** of "sit tall" (`CalibrationMath.steadiest`), and the step ends early once steady (at least 3 s). The forward axis is the dominant direction of the whole nod (`CalibrationMath.nod`), not its lowest sample. `SlouchTest.evaluate` sets the forward-tilt and shift limits 60% of the way from upright to your slouch. It never sets a limit at or above the slouch, sets the shift limit from real translation only (not tilt kinematics), and averages the second upright into neutral only if it agrees and isn't more slouched.

### Sign and frame conventions (easy to get wrong)

- **Acceleration:** `userAcceleration` is negated at the source in `HeadphoneMotion` (Apple's sign is opposite to physical motion). Everything downstream is physical, in m/s².
- **Gyro and attitude:** the gyro sign is *verified from data* (`GyroSignVoter`: gravity must rotate as `dg/dt = g × ω`). The CMAttitude matrix convention is also voted, in `WorldFrame`. Don't hard-code either.
- **Head frame:** `HeadCalibration` stores `neutralGravity`, `forward`, and `leverArm` in the AirPods frame; `up = -neutralGravity`, `left = up × forward`. Calibrations are stored per earbud **and** per desk mode (UserDefaults keys `calibration.<earbud>[.standing]`).

### Hunch learning

- **`HunchFeatureSet`:** legacy 8 summary features + ~28 multi-scale "extra" features computed from a stored 16-minute trace, including body-model features.
- **`BodyPoseFilter` (`BodyModel.swift`):** a 2-state Kalman filter that splits the head reading into trunk lean (slow, from forward position on an arc around the hips) and neck bend (fast, = pitch − trunk), plus sink (cm). It reads only the 4 stored trace channels, so live and saved-history features match. Never feed it `forwardSigmaCM` (not stored).
- **`HunchStateFilter`:** a sticky two-state hidden Markov filter turning per-second evidence (rules ±1, or graded model evidence up to ±1.5 outside the ±0.1 unsure band) into `hunchProbability`. Flag at ≥0.8, clear at ≤0.3. The step size is solved so ordinary evidence flags after `secondsToFlag`; sitting-tall evidence counts 2.5×, so a real correction clears it within ~30 s.
- **`HunchTrainer`:** compares logistic regression vs `BoostedTrees` with **time-blocked** CV, tunes the threshold, and only uses the model if it's trustworthy (`HunchClassifier.isUsable`: ≥10 distinct moments, ≥60% balanced accuracy). Answers less than 20 s apart count as one moment.
- **Storage:** answers live in `~/Library/Application Support/Posture/hunch-answers.json`. Retraining runs in a background `Task`.

### UI (`Sources/App/Views`)

- **`NotchPanel`:** a borderless non-activating `NSPanel` pinned to the notch. Hover is polled; content is pinned to the top so it can never slide under the notch.
- **`MenuView`:** a `MenuBarExtra(.window)`. Its `ScrollView` gets an explicit, measured height, because without it the popover collapses to almost nothing.
- **`HunchModelWindow`:** a manually managed `NSWindow`.

## Behaviors that were bugs before (don't regress)

Each of these has a regression test:

- **Abandoning a movement** (too long or implausible) restores the position from *before* the movement, never zero. A quick large vertical move (standing up or sitting down) is the only fresh start.
- **"Sat back up" reset** requires the movement to start tilted (more than 12°). The leftover-offset fade is ~8 h, not seconds. Both otherwise produce false "good posture" readings.
- **Brief disconnects and earbud switches** must not wipe the position estimate.
- **Resets clear the motion look-back buffer** (`resetFilters`, `RelativePositionTracker.zero`). Otherwise a movement within ~0.5 s rewinds to the pre-reset state and undoes the reset.
- **After a disconnect, the next sample is a gap** (`HeadphoneMotion.timeStep`; the spike filter and compensator are reset). Nothing is differenced across a dropout.
- **`Notifier.configure()` runs at launch** (delegate and check-in buttons). Only the permission prompt is deferred.
- **Calibration lookup goes through `HeadCalibration.best(for:mode:)`**, which falls back to `.unknown`-earbud calibrations, and is loaded in `init`. Some headphones never report an earbud.
- **Hunch cross-validation folds are assigned per moment** (`HunchTrainer.foldAssignment`), never per answer.
- **A head shift only gets the look-down grace when it's mostly tipping** (`PostureRules.checks`): the real movement alone is under the limit *and* the head is past the tilt limit or tipping is most of the shift. The slouch test's shift-limit floor (tipping to the tilt limit) is rounded **up**. Reading highlights use `LookDownGrace.hasRunOut`, not the 1 Hz countdown, so a new glance never flashes red.
- **Neutral-pose adaptation** (`adaptNeutral`) runs only while rated good and still, and is capped at 4° from the saved calibration.
- **Ding timing:** the ding plays exactly `holdSeconds` after the slouch is detected, once per slouch. A new slouch needs 10 s of good posture first. There's no long cooldown.

## Verifying visual changes

Screen capture isn't permitted in this environment, so check the UI with offscreen renders:

- **SwiftUI panels:** host the view in an `NSHostingView` in an offscreen `NSWindow`, then use `cacheDisplay`. `ImageRenderer` can't draw `ScrollView`. Compile `Sources/Core` + `Sources/App/PostureMonitor.swift` + `Sources/App/Views` + a small `main.swift` (not `PostureApp.swift`, it has `@main`).
- **Menu sizing:** check with `NSHostingController(...).sizeThatFits(in:)` using a small proposed height.
- **Realistic state:** compile with `-D DEBUG` and call `PostureMonitor.debugPreview(slouching:)` right before drawing (the live monitor can reset the preview while the run loop spins).
