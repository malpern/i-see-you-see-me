"""OAK-D Lite sensor service.

Sensor-first: this process produces observations (RGB frames + central-ROI
median depth) and ships them over a local WebSocket. All interpretation —
face detection, head pose, attention state — happens in the host app.

Protocol (one JSON text message per frame, ~10 fps):
    { "type": "frame", "jpeg": "<base64>", "depth_mm": 850.0, "ts": 1718040000.0 }

Run:  uv run oak-sensor            (real OAK-D Lite)
      uv run oak-sensor --mock     (synthetic frames, no hardware)
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import time

import cv2
import numpy as np

FPS = 10
JPEG_QUALITY = 70
PORT = 8765

clients: set = set()


def encode_frame(bgr: np.ndarray, depth_mm: float | None) -> str:
    ok, jpeg = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
    if not ok:
        raise RuntimeError("JPEG encode failed")
    return json.dumps(
        {
            "type": "frame",
            "jpeg": base64.b64encode(jpeg.tobytes()).decode("ascii"),
            "depth_mm": depth_mm,
            "ts": time.time(),
        }
    )


async def broadcast(message: str) -> None:
    dead = set()
    for ws in clients:
        try:
            await ws.send(message)
        except Exception:
            dead.add(ws)
    clients.difference_update(dead)


def central_median_depth(depth_frame: np.ndarray) -> float | None:
    """Median depth (mm) of the central third of the frame, zeros excluded.

    Crude but honest: the sensor reports a distance observation, the host
    decides what it means. Face-ROI depth lookup is the obvious upgrade.
    """
    h, w = depth_frame.shape[:2]
    roi = depth_frame[h // 3 : 2 * h // 3, w // 3 : 2 * w // 3]
    valid = roi[roi > 0]
    if valid.size < 50:
        return None
    return float(np.median(valid))


async def oak_loop() -> None:
    import depthai as dai

    pipeline = dai.Pipeline()

    cam = pipeline.create(dai.node.ColorCamera)
    cam.setPreviewSize(640, 360)
    cam.setInterleaved(False)
    cam.setColorOrder(dai.ColorCameraProperties.ColorOrder.BGR)
    cam.setFps(FPS)

    mono_left = pipeline.create(dai.node.MonoCamera)
    mono_right = pipeline.create(dai.node.MonoCamera)
    mono_left.setBoardSocket(dai.CameraBoardSocket.CAM_B)
    mono_right.setBoardSocket(dai.CameraBoardSocket.CAM_C)
    mono_left.setResolution(dai.MonoCameraProperties.SensorResolution.THE_400_P)
    mono_right.setResolution(dai.MonoCameraProperties.SensorResolution.THE_400_P)

    stereo = pipeline.create(dai.node.StereoDepth)
    stereo.setDefaultProfilePreset(dai.node.StereoDepth.PresetMode.HIGH_DENSITY)
    stereo.setLeftRightCheck(True)
    mono_left.out.link(stereo.left)
    mono_right.out.link(stereo.right)

    xout_rgb = pipeline.create(dai.node.XLinkOut)
    xout_rgb.setStreamName("rgb")
    cam.preview.link(xout_rgb.input)

    xout_depth = pipeline.create(dai.node.XLinkOut)
    xout_depth.setStreamName("depth")
    stereo.depth.link(xout_depth.input)

    with dai.Device(pipeline) as device:
        print("OAK-D Lite connected:", device.getDeviceName())
        q_rgb = device.getOutputQueue("rgb", maxSize=2, blocking=False)
        q_depth = device.getOutputQueue("depth", maxSize=2, blocking=False)
        depth_mm: float | None = None
        while True:
            d = q_depth.tryGet()
            if d is not None:
                depth_mm = central_median_depth(d.getFrame())
            frame = q_rgb.tryGet()
            if frame is not None and clients:
                await broadcast(encode_frame(frame.getCvFrame(), depth_mm))
            await asyncio.sleep(1 / (FPS * 4))


async def mock_loop() -> None:
    """Synthetic moving-blob frames so the whole stack runs with no hardware."""
    print("Mock sensor running (no OAK-D required)")
    t = 0.0
    while True:
        bgr = np.full((360, 640, 3), 30, dtype=np.uint8)
        x = int(320 + 200 * np.sin(t))
        cv2.circle(bgr, (x, 180), 60, (0, 200, 255), -1)
        depth_mm = 900 + 400 * float(np.sin(t / 3))
        if clients:
            await broadcast(encode_frame(bgr, depth_mm))
        t += 1 / FPS
        await asyncio.sleep(1 / FPS)


async def serve(mock: bool) -> None:
    import websockets

    async def handler(ws):
        clients.add(ws)
        print(f"Client connected ({len(clients)} total)")
        try:
            await ws.wait_closed()
        finally:
            clients.discard(ws)
            print(f"Client disconnected ({len(clients)} total)")

    async with websockets.serve(handler, "127.0.0.1", PORT, max_size=None):
        print(f"Sensor service on ws://127.0.0.1:{PORT}")
        if mock:
            await mock_loop()
        else:
            await oak_loop()


def cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mock", action="store_true", help="synthetic frames, no OAK-D")
    args = parser.parse_args()
    try:
        asyncio.run(serve(mock=args.mock))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    cli()
