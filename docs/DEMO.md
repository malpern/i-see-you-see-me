# Demo Script (3 minutes)

## Setup (before judges arrive)

```bash
# Terminal 1 — OAK-D sensor service (or --mock if hardware misbehaves)
cd sensor && uv run oak-sensor

# Menu bar app
cd app && open ISeeYou.app
```

Sanity check: menu bar eye icon visible, narration card populating, sensor picker on the source you want. If the OAK-D acts up, flip the picker to Built-in Camera — the demo continues.

## Beat 1 — The event stream (60s)

Open the menu bar app. Walk into frame: **person entered**. Look at the screen: **look started**. Look away quickly: **glance (0.8s)**. Stare for a few seconds: **attention held**.

> "This is a presence engine, not a face detector. Consumers never see frames, landmarks, or depth maps — only semantic events with hysteresis and dwell timing. The OAK-D Lite is treated as a smart sensor: it ships observations; all interpretation is host-side and swappable."

Point at the depth readout (OAK source): distance updates live; step back: **receding**.

## Beat 2 — Apple on-device AI, today's APIs (60s)

Click **Narrate**.

> "The narration is Apple's on-device foundation model — the FoundationModels framework, running locally on this Mac. Zero cloud, zero tokens. And note what it consumes: the event log only, never a single frame. The privacy boundary is architectural, not a policy promise."

The attention math itself is Apple's Vision framework — head yaw/pitch on the Neural Engine.

## Beat 3 — Monday's APIs (45s)

Open `MultimodalAttentionEstimator.swift` in Xcode 27.

> "At WWDC on Monday, Apple made Foundation Models multimodal — image attachments in prompts, macOS 27 only. Here's our attention estimator built on it: presence and attention classification as a structured-output prompt. It compiles under the Xcode 27 SDK today, sits behind the same `AttentionEstimator` protocol as the Vision estimator, and drops in on Golden Gate without touching the engine, the events, or the UI. The architecture we demoed is the upgrade path."

## Beat 4 — Why it matters (15s)

> "Attention-aware notifications, e-ink status boards that wake when you look at them, kiosks that know they're being watched. One reusable engine, semantic events out, everything on-device."

## Fallback matrix

| Failure | Move |
|---|---|
| OAK-D won't enumerate | Sensor picker → Built-in Camera |
| No hardware at all | `uv run oak-sensor --mock` (synthetic frames prove the protocol) |
| Foundation Models unavailable (Apple Intelligence off) | Event feed still demos; narrate the narration |
| Xcode 27 not ready | Show the gated file in any editor; the `#if MACOS27_SDK` flag tells the story |
