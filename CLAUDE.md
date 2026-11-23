# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Posture** is a native macOS menu-bar app (macOS 14+, Apple silicon). It tracks head posture from the AirPods motion sensors (`CMHeadphoneMotionManager`) and shows a live 3D bust in a panel around the MacBook notch. It alerts after sustained slouching. It's AirPods-only by design: no camera, no Apple Watch, no network. An iOS version existed briefly and was removed at the user's request, so don't re-add it.

## Commands

```sh
./build.sh                 # compile Sources/Shared + Sources/macOS with swiftc → build/Posture.app (ad-hoc signed)
open build/Posture.app     # run (it's an LSUIElement menu-bar app; `pkill -x Posture` before relaunching)
./test.sh                  # compile + run the whole test suite (exit code 1 on failure)
```

- **No SwiftPM, no Xcode project.** Everything is built with plain `swiftc -swift-version 5`. If the Xcode license isn't accepted, prefix with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
- **Adding files:** `build.sh` globs `Sources/Shared/*.swift Sources/macOS/*.swift`, but **`test.sh` lists Shared files explicitly**. A new Shared file needed by tests must be added to `test.sh`. Tests never compile `Sources/macOS` (it has the `@main`).
- **Tests:** a custom harness, not XCTest (`Tests/TestSupport.swift`: `test(...)`, `expect`, `expectNear`). `Tests/main.swift` calls each group function (`estimatorTests()`, `feelTests(resources:)`, …). There's no per-test filter. To run one group, temporarily call only that function in `main.swift`. Add a new test group by writing a `func xxxTests()` and calling it from `main.swift`.
- **No macros:** the Command Line Tools toolchain lacks the SwiftUI macro plugins, so `@State` / `@Observable` fail to compile there. Use `ObservableObject` + `@Published`, `@StateObject`, `@AppStorage` (property wrappers, not macros).

## Architecture

### Signal pipeline (all in `Sources/Shared`, driven by `PostureMonitor`)

`HeadphoneMotion` (~25 Hz) → `SpikeFilter` → `LeverArmCompensator` → three consumers:

1. **`PostureEstimator`:** head tilt (pitch/roll relative to the calibrated head frame, from gravity) plus head *position* (forward/down cm). Position = neck kinematics + a per-axis `ZUPTKalman` (position, velocity, accel bias) with zero-velocity updates when `StillnessDetector` says still.
2. **`RelativePositionTracker` (display only):** world-frame "Moved ↑/↔" readout. **Never** used for posture decisions.
3. **A second `RelativePositionTracker` + `DeskModeDetector`:** sitting/standing detection.

`PostureMonitor.tick()` (1 Hz) turns `reading` into reasons:
- `PostureRules` (forward tilt, side tilt, head shift; separate limits for sitting/standing).
- `HunchDetector` (+ personal `HunchClassifier`).

The reasons feed `SlouchTimer` (10-min alert) and `SlouchDingRule` (gentle ding), which in turn drive `Notifier` and `Chime`.

### Sign and frame conventions (easy to get wrong)

- **Acceleration:** `userAcceleration` is negated at the source in `HeadphoneMotion` (Apple's sign is opposite to physical motion). Everything downstream is physical, in m/s².
- **Gyro and attitude:** the gyro sign is *verified from data* (`GyroSignVoter`: gravity must rotate as `dg/dt = g × ω`). The CMAttitude matrix convention is also voted, in `WorldFrame`. Don't hard-code either.
- **Head frame:** `HeadCalibration` stores `neutralGravity`, `forward`, and `leverArm` in the AirPods frame; `up = -neutralGravity`, `left = up × forward`. Calibrations are stored per earbud **and** per desk mode (UserDefaults keys `calibration.<earbud>[.standing]`).
- **3D model space:** x = the model's **left**, y = up, z = facing direction. `+x` rotation tips the head/neck forward. 1 cm = `HeadScene.unitsPerCM` (0.205) model units.

### 3D bust

- **`HeadScene` (`HeadView.swift`):** a head scan (`Resources/Models/Head.glb`, CC-BY, credited in the README) loaded by `GLBLoader`, plus procedural strand hair (`Hair.swift`).
- **Rig:** three bones (shoulders → `neckBase` → `skullBase`, placed toward the spine), skinned by `HeadScene.skinWeights`.
- **`HeadAnimator`:** an `SCNSceneRendererDelegate` that smooths toward targets every frame. A forward shift is shown as **upper-body lean + neck bend**; the head never translates relative to the neck (that caused the "detached neck").
- **Head orientation:** tilt comes from gravity relative to the *saved calibration*; only yaw comes from attitude relative to launch.

### Hunch learning

- **`HunchFeatureSet`:** legacy 8 summary features + ~22 multi-scale "extra" features computed from a stored 16-minute trace.
- **`HunchTrainer`:** compares logistic regression vs `BoostedTrees` with **time-blocked** CV, tunes the threshold, and only uses the model if it's trustworthy (`HunchClassifier.isUsable`: ≥10 distinct moments, ≥60% balanced accuracy). Answers less than 20 s apart count as one moment.
- **Storage:** answers live in `~/Library/Application Support/Posture/hunch-answers.json`. Retraining runs in a background `Task`.

### UI (`Sources/macOS`)

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
- **Neutral-pose adaptation** (`adaptNeutral`) runs only while rated good and still, and is capped at 4° from the saved calibration.
- **Ding timing:** the ding plays exactly `holdSeconds` after the slouch is detected, once per slouch. A new slouch needs 10 s of good posture first. There's no long cooldown.

## Verifying visual changes

Screen capture isn't permitted in this environment, so check the UI with offscreen renders:

- **3D scene:** `SCNRenderer.snapshot` of `HeadScene(resources: Bundle(path: "Resources/Models")!)`. Pose with `setPose(..., immediate: true)` / `setOffset(..., immediate: true)`, because the animator only runs inside an `SCNView`.
- **SwiftUI panels:** host the view in an `NSHostingView` in an offscreen `NSWindow`, then use `cacheDisplay`. `ImageRenderer` can't draw `NSViewRepresentable` (the 3D view) or `ScrollView`.
- **Menu sizing:** check with `NSHostingController(...).sizeThatFits(in:)` using a small proposed height.
- **Realistic state:** compile with `-D DEBUG` and call `PostureMonitor.debugPreview(slouching:)`.
