# Demo Script (3 minutes)

## Setup (before judges arrive)

```bash
# Terminal 1 — OAK-D sensor service (auto-reattaches if the camera drops)
cd sensor && uv run --no-sync oak-sensor

# The app: eyes window opens at launch, menu bar eye icon for the internals
cd app && open ISeeYou.app
```

The app defaults to the OAK-D and falls back to the built-in camera by itself
if the OAK path goes quiet for 5 s — the demo cannot open on a dead sensor.

Sanity check: eyes wandering in the window, menu bar status shows your sensor,
events flowing. Have `MultimodalAttentionEstimator.swift` open in Xcode 27.

## Beat 1 — The eyes (60s, no narration needed at first)

Stand back, ignore it: the eyes wander with saccades and drift, sneaking the
occasional glance at you. Then look at it:

- Eyes **lock onto you** and follow as you move side to side
- **Blink** — it blinks back
- **Wink left, wink right** — it winks the matching eye
- **Go wide-eyed** — it goes wide, brows up
- **Close your eyes** — it closes its eyes until you open (the audience sees
  what you can't)
- Walk closer (OAK): **pupils dilate with proximity**
- Walk away and wait: drowsy lids, slow blinks, asleep

> "Everything you just saw is consuming five semantic events and a depth
> number. The eyes never see a camera frame."

## Beat 2 — What's underneath (60s)

Open the menu bar panel: live state, head yaw/pitch, distance, event feed
(person_entered, glance, attention_held…), and the narration card.

> "The OAK-D Lite is treated as a smart sensor — it ships observations over a
> WebSocket; all interpretation is host-side and swappable. Presence engine →
> semantic events → any consumer. The eyes are one consumer; this panel is
> another."

Click **Narrate**:

> "That summary is Apple's on-device foundation model — zero cloud, zero
> tokens — and it consumes only the event log, never frames. The privacy
> boundary is architectural."

Bonus depth flex: the iris itself is a procedural Metal shader; the pupil
diameter is a live parameter driven by the depth camera.

## Beat 3 — Monday's APIs (45s)

Show `MultimodalAttentionEstimator.swift` in Xcode 27:

> "At WWDC on Monday, Foundation Models went multimodal — image attachments
> in prompts, macOS 27 only. Here's our attention estimator built on it,
> using the shipping `Attachment` API — it compiles against the macOS 27 SDK
> released this week, sits behind the same `AttentionEstimator` protocol as
> the Vision-framework estimator we just demoed, and activates on Golden Gate
> without touching the engine, the events, or the eyes. The architecture is
> the upgrade path."

## Beat 4 — Why it matters (15s)

> "Attention-aware notifications, e-ink boards that wake when you look at
> them, kiosks that know they're being watched. One reusable presence engine,
> semantic events out, everything on-device."

## Fallback matrix

| Failure | Move |
|---|---|
| OAK-D won't enumerate | Nothing to do — app auto-falls back to built-in camera; demo loses only the depth beats |
| Sensor service dies | It auto-restarts the pipeline; worst case relaunch terminal 1 |
| Wink/wide detection flaky in venue lighting | Lead with blink + closure mirroring (most robust), skip winks |
| Foundation Models unavailable (Apple Intelligence off) | Event feed still demos; describe the narration |
| Everything on fire | Eyes window + built-in camera alone carry Beat 1, which is the demo |
