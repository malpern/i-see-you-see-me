import CoreGraphics
import Foundation
import Vision

/// Per-frame estimate produced by an attention estimator.
struct AttentionEstimate {
    let facePresent: Bool
    /// Yaw/pitch in degrees. 0/0 = facing the camera straight on.
    let yawDegrees: Double
    let pitchDegrees: Double
    /// True when the head orientation is within the "looking at target" cone.
    let isLooking: Bool
    /// Face center in the frame, normalized 0-1 (Vision coordinates: y up).
    var faceCenter: CGPoint? = nil
    /// True while the person's eyes are closed (blink or shut).
    var eyesClosed: Bool = false
}

/// A swappable attention estimator — the heart of the modular architecture.
/// Today: Vision-framework geometry (macOS 26, hardware-accelerated).
/// Tomorrow: the macOS 27 multimodal Foundation Models estimator
/// (see MultimodalAttentionEstimator.swift) drops in behind the same protocol.
protocol AttentionEstimator {
    func estimate(from frame: SensorFrame) -> AttentionEstimate
}

/// Geometry-based estimator using Apple's Vision framework.
/// VNDetectFaceRectanglesRequest yields head yaw/pitch/roll directly,
/// running on the Neural Engine — no Python, no model downloads.
final class VisionHeadPoseEstimator: AttentionEstimator {
    /// Attention cone half-angles. Generous on pitch because people sit
    /// below/above camera; tighter on yaw, the stronger looking-away signal.
    var yawThresholdDegrees: Double = 22
    var pitchThresholdDegrees: Double = 18

    func estimate(from frame: SensorFrame) -> AttentionEstimate {
        // Landmarks (not just rectangles): the eye contours give us blinks.
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: frame.image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return AttentionEstimate(facePresent: false, yawDegrees: 0, pitchDegrees: 0, isLooking: false)
        }

        // Largest face = nearest person. Multi-person policy comes later (PLAN §6).
        guard let face = (request.results ?? [])
            .max(by: { $0.boundingBox.area < $1.boundingBox.area })
        else {
            return AttentionEstimate(facePresent: false, yawDegrees: 0, pitchDegrees: 0, isLooking: false)
        }

        let yaw = (face.yaw?.doubleValue ?? 0) * 180 / .pi
        let pitch = (face.pitch?.doubleValue ?? 0) * 180 / .pi
        let looking = abs(yaw) <= yawThresholdDegrees && abs(pitch) <= pitchThresholdDegrees
        return AttentionEstimate(
            facePresent: true,
            yawDegrees: yaw,
            pitchDegrees: pitch,
            isLooking: looking,
            faceCenter: CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY),
            eyesClosed: Self.eyesClosed(face)
        )
    }

    /// Eye-aspect-ratio blink detection: when the lid closes, the eye
    /// contour's height collapses relative to its width.
    private static func eyesClosed(_ face: VNFaceObservation) -> Bool {
        guard let landmarks = face.landmarks,
              let left = landmarks.leftEye, let right = landmarks.rightEye
        else { return false }

        func aspect(_ region: VNFaceLandmarkRegion2D) -> CGFloat {
            let pts = region.normalizedPoints
            guard pts.count >= 4,
                  let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
                  let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max(),
                  maxX > minX
            else { return 1 }
            return (maxY - minY) / (maxX - minX)
        }

        return (aspect(left) + aspect(right)) / 2 < 0.18
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
