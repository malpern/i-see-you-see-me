# i-see-you-see-me

A real-time presence and attention sensing platform built on the [OAK-D Lite](https://shop.luxonis.com/products/oak-d-lite) depth camera — with attention math and on-device AI narration running natively on macOS.

Built for the WWDC26 YC hackathon.

## Quick Start

```bash
# Menu bar app (macOS 26+, Apple Silicon)
cd app && MENU_BAR_APP=1 ./Scripts/package_app.sh release && open ISeeYou.app

# OAK-D sensor service (optional — app falls back to the built-in camera)
cd sensor && uv sync && uv run oak-sensor          # or --mock without hardware
```

Then pick "OAK-D Lite" in the menu bar app's sensor picker.

## How It Works

```
OAK-D Lite ──(DepthAI, Python)──► frames + depth over WebSocket ─┐
                                                                 ├─► Vision framework head pose
Built-in camera ──(AVFoundation)─────────────────────────────────┘        │
                                                                          ▼
                                                  AttentionEngine (hysteresis + dwell timers)
                                                                          │ semantic events
                                                                          ▼
                                      menu bar UI + on-device Foundation Models narration
```

- **Sensors produce observations, never interpretations** — the Python service ships JPEG frames and a median depth scalar, nothing else.
- **Attention estimation is a swappable protocol** — today it's Vision-framework head pose (`VisionHeadPoseEstimator`); the WWDC26 multimodal Foundation Models estimator ([MultimodalAttentionEstimator.swift](app/Sources/ISeeYou/Narration/MultimodalAttentionEstimator.swift)) compiles under the Xcode 27 SDK and drops in behind the same protocol on macOS 27.
- **Consumers see only semantic events** (`person_entered`, `glance`, `attention_held`, …) — and the narration layer proves it: Apple's on-device foundation model describes your engagement from the event log alone, never seeing a single frame.

The OAK-D Lite is treated as a smart sensor that produces observations. The host software is responsible for interpretation, emitting high-level semantic events like `look_started`, `attention_held`, and `person_entered` — never raw landmarks or depth maps.

## Goals

Answer questions like:

- Is someone present?
- Where are they located relative to the device?
- Are they looking at the device?
- How long have they been paying attention?
- Did they glance briefly or intentionally engage?
- Are they approaching or moving away?

## Hardware

- **Camera:** OAK-D Lite (Luxonis) — 1080p RGB, stereo depth, on-device AI inference over USB-C
- **Primary dev machine:** MacBook Air M4
- **Secondary compute:** Mac Mini M4 Pro (64 GB) for model experimentation, logging, training

## Software Direction

Primary stack under evaluation:

- **DepthAI** — camera control, depth acquisition, face/person detection, pipeline management
- **OpenCV** — frame manipulation, geometry, debug overlays, calibration
- **MediaPipe** — face mesh / head pose / eye landmarks, used selectively
- **Modern vision models** — ONNX Runtime, CoreML, lightweight gaze-estimation models, optionally Florence- or SmolVLM-class models

Traditional geometry-based approaches will be evaluated against VLM approaches for latency-sensitive tasks. Newer is not assumed to be better.

## Event Stream

The platform emits high-level events. Example shapes:

```json
{ "event": "look_started" }
{ "event": "look_ended" }
{ "event": "glance" }
{ "event": "attention_held", "duration_ms": 3500 }
{ "event": "person_entered" }
{ "event": "person_left" }
```

Consumer-facing API (illustrative):

```swift
presenceEngine.subscribe { event in
    switch event {
    case .attentionHeld: ...
    case .lookStarted: ...
    }
}
```

## Initial Success Criteria

| Capability | Target |
|---|---|
| Presence detection | >99% reliability indoors |
| Head tracking (location, orientation, distance) | <100 ms latency |
| Attention detection | Reliable with glasses, stable under office lighting, low false positives, low jitter |
| Engagement classification | Distinguish passing glance / short look / focused attention |

## Calibration

The system supports calibration of arbitrary targets (monitors, e-ink displays, wall panels, appliances, kiosks). A target is declared like:

```json
{ "target": "left_monitor" }
```

…and the system estimates whether attention is directed at it.

## Architecture Principles

- **Sensor first** — the OAK-D Lite produces observations; it does not contain application logic.
- **Event driven** — applications consume semantic events, not raw vision data.
- **Low latency** — a slightly less accurate answer in 50 ms beats a perfect answer in 500 ms.
- **Modular** — face detector, gaze estimator, attention classifier, and event generator should each be swappable.

## Future Applications

The current objective is the reusable sensing platform — not the apps built on top. Downstream possibilities include:

- Attention-aware notification displays
- Smart e-ink status boards
- Desktop presence detection / auto-hide UI
- Home automation triggers
- Occupancy sensing
- Accessibility interfaces
- Health and wellness monitoring
- Context-aware productivity systems

## Status

Greenfield. No code yet — this repo currently holds the project brief.
