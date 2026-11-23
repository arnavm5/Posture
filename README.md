# Posture

**A native macOS posture coach that lives in your MacBook's notch and uses the motion sensors in your AirPods.**

Posture tracks your head in real time, shows a live 3D mannequin that mirrors it, and nudges you when
you've been slouching for too long (10 minutes by default).

- **Live in the notch:** a small black panel wraps around the camera housing and shows your status
  and slouch timer. Hover over it to see the live 3D bust and your numbers.
- **Tilt and position:** forward tilt and side tilt are measured separately, and the app estimates
  how far your head has moved forward or down compared with your calibrated "sitting tall" pose.
- **Forgiving timer:** glancing at your keyboard doesn't count. The timer only resets after 30 seconds
  of good posture, and the status updates instantly so you can see you've corrected.
- **Private:** everything runs on-device. No camera, no network, no accounts.

---

## Requirements

| | |
|---|---|
| Mac | macOS 14 Sonoma or later (Apple silicon) |
| Headphones | AirPods Pro, AirPods (3rd gen or later), AirPods Max, or Beats Fit Pro |
| Build tools | Xcode **or** just the Command Line Tools (`xcode-select --install`) |

## Build and run

```sh
./build.sh
open build/Posture.app
```
`build.sh` compiles `Sources/Shared` + `Sources/macOS` with `swiftc`, assembles `build/Posture.app`,
copies the 3D model into it, and ad-hoc signs it. Copy it to `/Applications` and turn on
**Launch at login** from the menu if you want to keep it.

## First run: calibration (about 15 seconds)

Put your AirPods in and choose **Calibrate**. Four short steps:

1. **Sit tall** and look at your screen. This sets "up".
2. **Look down** at your keyboard and back up. This sets "forward".
3. **Turn** your head left, then right.
4. **Tilt** each ear toward its shoulder.

Steps 3 and 4 let the app measure where your AirPods sit relative to the point your neck pivots on
(the "lever arm"), which is what makes the position tracking accurate. Each AirPod keeps its own
calibration, so if your data switches to the other earbud you'll be asked to calibrate it once.
After you take the AirPods out and put them back in, the app suggests recalibrating.

## What counts as slouching

You're slouching if **any** of these is true, compared with your calibrated pose:

| Check | Default |
|---|---|
| Head tipped forward | more than **15°** |
| Head tilted sideways | more than **12°** |
| Head moved forward | more than **5 cm** |
| Head dropped lower | more than **5 cm** |

Plus **hunched shoulders** (see below). All four are adjustable. A **gentle ding** plays 1 second after a slouch is detected (adjustable from "right away" to 30 s in
Alerts & sounds). Every new slouch dings once; a slouch counts as new after 10 seconds of sitting well, so
hovering right at the limit doesn't nag. After **10 minutes** of slouching you get a notification and the notch
drops open with an orange glow, with a **two-note chime**, then again every 10 minutes if you keep slouching. Taking your
AirPods out pauses tracking; **Pause 1 hour** silences it.

## Hunched shoulders (AirPods only, learns from you)

AirPods can't see your shoulders, but hunching changes how your head sits: as your upper back rounds,
your head moves forward and down while your chin stays level or tips *up* to keep your eyes on the
screen. Looking down at a keyboard is the opposite (head tips down), so it doesn't count. Hunching also
creeps in, and a slow upward drift of the chin over several minutes is visible even when the movement
itself is too slow to feel.

- **Built-in rules (day one):** the chin-poke pattern held for a minute, or a slow chin-up drift,
  adds "shoulders hunched" as a slouch reason.
- **Teach it your hunch:** tap **I'm hunched** or **I'm fine** (menu-bar menu or the notch). Each tap
  labels the moment *5 seconds before* the tap (by the time you tap you've usually started sitting up) and
  stores the last 16 minutes of head data with it. Tapping again within 10 s replaces your last answer.
- **Your model:** two models are trained on your answers and compared fairly. **Logistic regression** is a
  weighted sum of signals. **Gradient-boosted decision trees** add up many small yes/no trees, so they learn
  combinations and thresholds ("head forward *and* chin up, but not while looking down"). They use about 30
  signals: 10-second, 2-minute and 15-minute views, trends, and how you compare with *your own* normal
  for that session. Both are scored on blocks of time they didn't train on, and the better one is used,
  with its "hunched" cutoff tuned to balance catches against false alarms.
- **Only used when it's reliable:** answers under 20 seconds apart describe the same moment and count once.
  Your model only takes over from the built-in rules once it covers at least 10 distinct moments and
  scores at least 60% on answers it didn't learn from. Everything runs and stays on your device.
- **Ask me now:** sends the check-in notification immediately instead of waiting for a good moment.
  Answering Yes or No on it records the last 30 seconds, exactly like the Hunched / Fine buttons.
- **Check-ins:** now and then (at most every 20 minutes, only at moments where your answer would teach
  it the most) you get "Are your shoulders hunched right now?" with Yes / No buttons on the notification.
  They stop once the model is confident (40+ answers, 85%+ match). Turn them off in settings.

It can't see your shoulders directly, so a subtle hunch with a perfectly still head can slip through.

### Seeing how well the hunch model works
Menu ▸ **Hunch model…** opens a window with:
- your answer counts and how close you are to a personal model (20 answers, at least 5 of each);
- **accuracy, catch rate and false-alarm rate**, measured fairly with 5-fold cross-validation (each
  answer is predicted by a model trained *without* it, so the numbers aren't flattering themselves);
- a live track record: how often the model agreed with you *before* you answered;
- the head signals your model relies on most (for example "chin-poke pattern", "head further forward");
- the check-in toggle, **Ask me now**, and **Forget all my answers**.

## Standing desk

Posture tells sitting from standing by how far your head rises or drops: standing up is roughly a
40–60 cm rise, so a settled rise of more than 30 cm switches to **Standing**, and a matching drop switches
back to **Sitting**. It only decides once you've settled, small shifts and slow drift are ignored, and you
can correct it with the **Sitting / Standing** switch in the menu.

- **Time today:** sitting and standing time are shown in the menu and the notch.
- **Separate calibration:** calibrate once while standing; sitting and standing each keep their own
  calibration (per AirPod), because your neutral head angle differs. Until you do, the sitting
  calibration is used and the app reminds you.
- **Separate limits:** the tilt and head-shift limits apply to whichever position you're in (standing
  defaults: 18° forward, 12° side, 6 cm), and the menu steppers edit the current one.
- **Fresh start:** switching position resets the slouch timer and the hunch pattern, since moving
  between sitting and standing is itself a posture break.

## Position readout (display only)

The menu and notch also show how far your head has moved since you last pressed **Zero**: `↑` is height change
and `↔` is horizontal distance, with an uncertainty. Standing up shows about +50 cm. This number is
**never** used for posture detection. Long continuous motion such as walking around can't be tracked
reliably, so that movement is skipped and the readout is marked `≈` until you zero it.

## How it works

. **Clean the raw stream.** One-sample glitches (a reading far from both neighbours while the neighbours
   agree, which real movement never produces) are replaced by the neighbours' average, and gaps from dropped
   Bluetooth samples are flagged so nothing is differenced or integrated across them. Costs one sample (~40 ms).
1. **Sign-correct the sensors.** Core Motion's user acceleration points opposite to the real motion;
   it's flipped once at the source. The gyroscope's sign is *verified from the data*, since gravity must
   rotate in the earbud's frame as `dg/dt = g × ω`.
2. **Remove the earbud's swing.** AirPods sit several centimetres from your neck's pivot, so every nod
   or turn swings them and the accelerometer reports movement that didn't happen:
   `a_earbud = a_head + α × r + ω × (ω × r)`. With the gyroscope (`ω`, `α`) and the calibrated lever
   arm `r`, the swing is subtracted out.
3. **Kalman filter per axis** (position, velocity, accelerometer bias). Whenever you're still, a
   zero-velocity update pins velocity to zero, which also corrects position and learns the bias.
   The filter's uncertainty is shown as `±`. A short look-back buffer replays the first half-second
   of each movement, which stillness detection only notices after it has started.
4. **Head frame.** Forward tilt and side tilt come from gravity in the calibrated head frame.
   Position adds neck kinematics (tipping forward moves the head forward and down) to the filtered
   translation.

**Following AirPod shifts:** while you're sitting well and holding still, your neutral pose slowly follows
small changes in how the AirPods sit (about 15 minutes to follow, only toward poses within 6° of neutral,
never more than 4° from your saved calibration in total, so a slow slouch can't become the new normal).
Toggle it under Calibration & position.

Honest limits: a very slow drift (sliding down over half a minute or more) is below the sensor's
noise floor and can't be seen. Large movements like standing up reset the posture position estimate.
A held slouch stays detected: the estimate doesn't drift while you're still, so it only fades back on an
overnight scale (about 8 hours) as a last-resort bound. Sitting back up after slouching with your head
tipped snaps the estimate back to neutral; a slump that ends with your eyes level on the screen does not.

### The 3D bust
A head scan rendered as a soft, warm-clay sculpture (eyes softened, gentle lighting, seen from a
three-quarter side angle that shows forward-head posture best) with SceneKit, rigged with three joints (shoulders, base of the neck, base of the skull, placed along the
spine). A forward head shift is shown the way a slouch really happens: the upper back rounds a little and
the neck bends forward, while the head keeps pointing exactly where your AirPods say. The head never slides
over the shoulders, which is what made the neck look detached. The female bust is the same
scan reshaped in code. Hair is strand-based: about 1,000 guide strands grown from the scalp in the shape
of the hairstyle, each with a clump of child strands, about 15,000 tapered ribbons in total. A faint
floor-and-wall grid behind the bust adds depth. Motion is smoothed every frame: AirPods readings (~25 per second) set a
target and the head glides toward it, with heavy smoothing when you're still (no jitter) and light smoothing
when you move (no lag).

## Tests

```sh
./test.sh
```

Compiles and runs the suite in `Tests/` with plain `swiftc` (no Xcode project needed). It covers:
- **Posture estimator:** leaning, slumping, sitting back, noise, bias learning, uncertainty,
  forward vs side tilt, the "lurch after an alert" regression, drift relaxation.
- **Motion processing:** Kalman integration and bias learning, gyro sign confirmation, lever-arm
  compensation, fitting the lever arm from the calibration moves, and an end-to-end check that
  nodding doesn't fake a head movement.
- **Calibration and rules:** head-frame solve, failure cases, per-earbud storage, slouch rules.
- **Hunch detection:** sitting tall, chin poke, keyboard glances, slow drift, break handling,
  model training and held-out accuracy, a personal pattern overriding the rules, storage.
- **Standing desk and model performance:** stand-up / sit-down detection, ignoring shuffles and
  drift, manual correction, per-position calibrations, honest cross-validation, live agreement record.
- **Slouch timer**, **relative position tracker** (stand up / sit down, no drift, walking, world frame).
- **3D model and hair:** loading, smoothing, female morph, scalp fitting, both hairstyles, style
  switching, and the background grid.

## Project layout

```
Sources/
  Shared/                 Motion, calibration, estimation, 3D bust (UI-independent core)
    HeadphoneMotion.swift   CMHeadphoneMotionManager stream (gravity, accel, gyro, earbud)
    MotionProcessing.swift  Kalman filter, stillness detector, gyro sign check, lever-arm compensation + fit
    HeadCalibration.swift   4-step calibration result, per-earbud storage
    PostureEstimator.swift  Tilt + head-position estimate
    PostureRules.swift      What counts as slouching
    HunchDetector.swift     Hunched-shoulder rules, personal model, labelled examples
    DeskMode.swift          Sitting / standing detection
    SlouchTimer.swift       The forgiving slouch clock
    RelativePosition.swift  Display-only "how far has my head moved" tracker
    PostureMonitor.swift    Ties it together: calibration flow, 1 Hz loop, alerts, settings
    HeadView.swift          SceneKit scene: rigged bust, materials, lighting, grid
    Hair.swift              Strand-based hairstyles, female bust morph, scalp fitting
    GLBLoader.swift         Minimal .glb reader and mesh smoothing
    Platform.swift          Small AppKit/SceneKit helpers
    Notifier.swift          Notifications
  macOS/                  Menu bar, notch panel, Hunch Model window
Resources/                Mac Info.plist, Models/ (head scan, normal map, license)
Tests/                    Test suite (run with ./test.sh)
build.sh, test.sh         Build and test scripts
```

## Troubleshooting

| Problem | Fix |
|---|---|
| "Waiting for AirPods…" never goes away | Check the AirPods are connected to this Mac and are a supported model. Allow Posture under System Settings ▸ Privacy & Security ▸ Motion & Fitness. |
| No notifications | System Settings ▸ Notifications ▸ Posture ▸ Allow. Use **Test alert** to check. |
| The 3D head moves the wrong way | Edit `pitchSign`, `yawSign` or `rollSign` at the top of `Sources/Shared/HeadView.swift`. |
| Numbers look off after re-seating the AirPods | Choose **Recalibrate**. |

## Credits

3D head: "Infinite, 3D Head Scan" by Lee Perry-Smith, licensed under
[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), based on a work at www.triplegangers.com
(obtained via the three.js examples). Rendered here as an untextured mannequin with procedurally
generated hair. See `Resources/Models/Head-LICENSE.txt`.
