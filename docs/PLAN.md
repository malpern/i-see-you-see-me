# Project Plan: Presence & Attention Sensing Platform

> Working name: **i-see-you-see-me**
> Last updated: 2026-06-10

This document describes how we get from an empty repo to a reusable presence engine built on the OAK-D Lite. It complements the [README](../README.md), which holds the project brief; this file holds the execution plan.

---

## 1. Guiding Constraints

These come straight from the brief and should win any argument during implementation:

1. **Sensor first.** The OAK-D Lite produces observations. Interpretation lives on the host. No application logic on-device beyond detection models.
2. **Event driven.** Consumers see semantic events (`look_started`, `person_left`), never landmarks, depth maps, or gaze vectors.
3. **Low latency over sophistication.** A decent answer in 50 ms beats a perfect one in 500 ms. Every component gets a latency budget.
4. **Modular.** Face detector, gaze estimator, attention classifier, and event generator are swappable behind interfaces.
5. **Don't assume newer is better.** Geometry-based approaches are the baseline; VLM/transformer approaches must beat them on accuracy *and* fit the latency budget to displace them.

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│ OAK-D Lite (DepthAI pipeline)                                   │
│   RGB frames · stereo depth · on-device face/person detection   │
└───────────────┬─────────────────────────────────────────────────┘
                │ observations (detections + depth + frames)
┌───────────────▼─────────────────────────────────────────────────┐
│ Observation Layer (host)                                        │
│   normalizes raw DepthAI output into typed Observation records  │
└───────────────┬─────────────────────────────────────────────────┘
                │ Observation stream
┌───────────────▼─────────────────────────────────────────────────┐
│ Estimation Layer (pluggable)                                    │
│   presence · head pose · gaze vector · distance/trajectory      │
└───────────────┬─────────────────────────────────────────────────┘
                │ Estimate stream (per-frame state)
┌───────────────▼─────────────────────────────────────────────────┐
│ Interpretation Layer                                            │
│   state machine: hysteresis, debouncing, dwell timers,          │
│   target intersection (calibrated targets)                      │
└───────────────┬─────────────────────────────────────────────────┘
                │ semantic events
┌───────────────▼─────────────────────────────────────────────────┐
│ Event API                                                       │
│   subscribe() · JSON event stream · transports (IPC/WS/MQTT)    │
└─────────────────────────────────────────────────────────────────┘
```

Each layer only consumes the layer above it. Swapping a gaze estimator touches the Estimation layer only; adding a new event type touches Interpretation only.

## 3. Technology Decisions (initial)

| Concern | Initial choice | Rationale / fallback |
|---|---|---|
| Language | Python 3.11+ | Fastest path with DepthAI SDK; performance-critical paths can move later |
| Camera SDK | `depthai` (v3 API) | Official Luxonis SDK; pipelines run on-device |
| Face/person detection | On-device models via DepthAI model zoo | Offloads host; proven blobs exist |
| Head pose / landmarks | MediaPipe Face Mesh **or** on-device landmark model | Benchmark both; pick by latency + glasses robustness |
| Gaze estimation | Geometry from head pose + eye landmarks (baseline) | Compare vs. lightweight gaze models (e.g. L2CS-Net ONNX) |
| Event transport | In-process pub/sub first; JSON over WebSocket second | MQTT adapter later for home automation |
| Packaging | `uv` + `pyproject.toml` | Modern, fast, reproducible |
| Visualization/debug | OpenCV windows + recording harness | Needed from week one for tuning |

All of these are *defaults to be validated in Phase 0–1*, not commitments.

## 4. Phases

### Phase 0 — Bring-up & Groundwork (~1 week)

Goal: camera streams reliably on the MacBook Air; repo has working scaffolding.

- [ ] Project scaffolding: `pyproject.toml`, `uv` env, lint (ruff), pytest, CI (GitHub Actions: lint + unit tests, no camera needed)
- [ ] DepthAI hello-world: RGB + depth preview at target FPS over USB-C
- [ ] Measure baseline: end-to-end frame latency, FPS, CPU usage on M4
- [ ] Recording harness: capture synchronized RGB + depth clips to disk for offline replay (critical — lets us iterate without sitting in front of the camera)
- [ ] Replay harness: feed recorded clips through the pipeline as if live

**Exit criteria:** live preview works; a recorded clip can be replayed through the same code path as the live camera.

### Phase 1 — Presence (~1–2 weeks)

Goal: rock-solid "is someone there, and where?"

- [ ] On-device person + face detection running in the DepthAI pipeline
- [ ] Fuse detection with depth → 3D position (x, y, z) relative to camera
- [ ] Observation layer: typed records, timestamps, confidence
- [ ] Interpretation: `person_entered` / `person_left` with hysteresis (no flapping when detection flickers)
- [ ] Trajectory: approaching / receding / static from z-velocity
- [ ] Test suite against recorded clips (entering, leaving, lingering at edge of frame, two people)

**Exit criteria:** >99% presence accuracy on the recorded test set; events are stable (no enter/leave flapping) across a 1-hour live office session.

### Phase 2 — Head Pose & Distance (~2 weeks)

Goal: know where the head is and which way it points, fast.

- [ ] Face landmarks → head pose (yaw/pitch/roll) — benchmark MediaPipe vs. on-device options
- [ ] Head position in 3D using depth at face ROI
- [ ] Latency budget enforcement: instrument every stage; target <100 ms capture-to-estimate
- [ ] Jitter handling: One Euro filter (or similar) on pose angles
- [ ] Debug overlay: draw pose axes, distance, FPS, per-stage latency on preview

**Exit criteria:** <100 ms median latency capture→head-pose; pose stable enough that a fixed observer produces <2° jitter.

### Phase 3 — Attention & Gaze (~2–3 weeks)

The hard part. Two tracks, evaluated against each other:

- **Track A (baseline): geometry.** Head pose cone + eye landmark refinement. Attention = gaze ray intersects target volume.
- **Track B (challenger): learned gaze.** Lightweight gaze-estimation model (ONNX/CoreML, e.g. L2CS-Net-class) running on host or device.

Work items:

- [ ] Target calibration: define a target (e.g. `left_monitor`) as a 3D region relative to the camera; guided calibration flow (look at corners)
- [ ] Gaze-ray / target intersection math + tolerance model
- [ ] Evaluation rig: ground-truth protocol (scripted look/don't-look sessions, with glasses and without, varied lighting), scored offline against recordings
- [ ] Pick winner per the brief's criteria: works with glasses, stable in office lighting, low false positives, low jitter — within latency budget

**Exit criteria:** attention detection meets the brief's reliability bar on the evaluation set; decision recorded in `docs/decisions/` with benchmark numbers.

### Phase 4 — Engagement Semantics & Event API (~1–2 weeks)

Goal: the consumer-facing product surface.

- [ ] Interpretation state machine: `glance` vs `short_look` vs `attention_held` from dwell times (thresholds configurable)
- [ ] Full event vocabulary: `look_started`, `look_ended`, `glance`, `attention_held {duration_ms}`, `person_entered`, `person_left`, approach/recede
- [ ] Event API: in-process subscribe, plus JSON stream over WebSocket
- [ ] Config file: targets, thresholds, model selection — no code changes to retune
- [ ] Minimal demo consumer (e.g. menu-bar dot or terminal dashboard that mirrors events live)

**Exit criteria:** an external process can subscribe over WebSocket and correctly mirror a person's engagement in real time.

### Phase 5 — Hardening & Platformization (ongoing)

- [ ] Long-run stability (24 h soak, USB reconnect recovery)
- [ ] Multi-person handling policy (nearest person? all persons with IDs?)
- [ ] Mac Mini role: heavier model experiments, log aggregation, evaluation runs
- [ ] Packaging as a service (launchd) with health endpoint
- [ ] MQTT/home-automation adapter
- [ ] API stability review → tag v0.1

## 5. Evaluation & Testing Strategy

- **Recordings are the test corpus.** Every behavior (enter, leave, glance, stare, glasses, backlight) gets recorded clips checked into a data store (not git — use local storage or LFS later). The replay harness makes every pipeline change scoreable offline.
- **Unit tests** for geometry, state machines, and event logic run in CI without hardware.
- **Latency instrumentation is permanent**, not a debugging afterthought — every stage reports timing, surfaced in the debug overlay and logs.
- **Benchmarks are decisions.** Whenever two approaches compete (MediaPipe vs. on-device landmarks, geometry vs. learned gaze), the comparison is run on the shared corpus and the result written to `docs/decisions/NNN-*.md`.

## 6. Risks & Open Questions

| Risk | Mitigation |
|---|---|
| Glasses break landmark/gaze models | Make glasses a first-class test condition from Phase 2 onward |
| macOS + DepthAI USB quirks (permissions, reconnects) | Address in Phase 0 bring-up; soak test in Phase 5 |
| MediaPipe on Apple Silicon performance | Benchmark early; on-device landmark models are the fallback |
| Gaze accuracy insufficient at desk distances (50–80 cm) | Head-pose-only attention may be acceptable for monitor-sized targets; eval rig will tell us |
| Multi-person scenes confuse single-person logic | Explicitly out of scope until Phase 5; nearest-person policy until then |
| Latency budget blown by host-side models | Prefer on-device inference; CoreML conversion as escape hatch |

Open questions to resolve as we go:

- Event schema versioning — decide before any external consumer exists (Phase 4).
- Should the engine expose *state* (current attention) in addition to *events*? Likely yes — a queryable snapshot API.
- Identity: do we ever need to know *who* is present, or only *that* someone is? (Privacy default: no identity.)

## 7. Repository Layout (planned)

```
i-see-you-see-me/
├── README.md            # project brief
├── docs/
│   ├── PLAN.md          # this file
│   └── decisions/       # benchmark-backed decision records
├── src/presence/
│   ├── capture/         # DepthAI pipeline, replay harness
│   ├── observe/         # observation layer (typed records)
│   ├── estimate/        # presence, head pose, gaze (pluggable)
│   ├── interpret/       # state machines → semantic events
│   └── api/             # subscribe, WebSocket, config
├── tools/               # recording, calibration, debug viewers
└── tests/
```

## 8. Immediate Next Steps

1. Phase 0 scaffolding (`uv init`, ruff, pytest, CI)
2. DepthAI hello-world on the MacBook Air — verify the OAK-D Lite enumerates and streams
3. Recording + replay harness
4. Start the Phase 1 presence pipeline
