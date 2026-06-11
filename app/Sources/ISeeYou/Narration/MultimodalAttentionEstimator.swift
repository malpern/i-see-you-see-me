import Foundation

// MARK: - The WWDC26 estimator (macOS 27 "Golden Gate")
//
// Announced June 8, 2026: the Foundation Models framework gains multimodal
// prompts — image attachments alongside text — so the on-device model can
// answer questions about frames directly ("What's new in the Foundation
// Models framework", WWDC26 session 241).
//
// That turns attention classification into a prompt instead of a model
// deployment: no ONNX conversion, no gaze-model sourcing, no calibration.
// Because estimators are protocol-typed (AttentionEstimator), this drops in
// next to VisionHeadPoseEstimator without touching the engine, the events,
// or the UI — the architecture's whole thesis in one swap.
//
// This file compiles only under the Xcode 27 / macOS 27 SDK: build with
//   swift build -Xswiftc -DMACOS27_SDK
// and runs only on macOS 27 (runtime-gated below). On macOS 26.5 the app
// uses the Vision-framework geometry estimator.

#if MACOS27_SDK
import CoreGraphics
import FoundationModels

@available(macOS 27.0, *)
final class MultimodalAttentionEstimator: AttentionEstimator {

    @Generable
    struct FrameAssessment {
        @Guide(description: "Is a person visible in the frame?")
        var personVisible: Bool
        @Guide(description: "Is the person looking toward the camera/screen?")
        var lookingAtScreen: Bool
        @Guide(description: "Approximate head yaw in degrees, 0 = facing camera")
        var headYawDegrees: Double
        @Guide(description: "Approximate head pitch in degrees, 0 = level")
        var headPitchDegrees: Double
    }

    private let session = LanguageModelSession(instructions: """
        You assess single frames from a workspace presence sensor. Report only \
        what is visible. Be conservative: if no person is clearly visible, \
        personVisible is false.
        """)

    func estimate(from frame: SensorFrame) -> AttentionEstimate {
        // Synchronous bridge for the demo; production would make the
        // estimator protocol async.
        let semaphore = DispatchSemaphore(value: 0)
        var result = AttentionEstimate(facePresent: false, yawDegrees: 0, pitchDegrees: 0, isLooking: false)
        Task {
            defer { semaphore.signal() }
            do {
                // WWDC26: image attachments ride along with the text prompt.
                // Attachment<ImageAttachmentContent> is PromptRepresentable,
                // so it composes directly in the PromptBuilder.
                let prompt = Prompt {
                    "Assess presence and attention in this frame."
                    switch frame.payload {
                    case .pixelBuffer(let buffer): Attachment(buffer)
                    case .cgImage(let image): Attachment(image)
                    }
                }
                let assessment = try await session.respond(
                    to: prompt,
                    generating: FrameAssessment.self
                ).content
                result = AttentionEstimate(
                    facePresent: assessment.personVisible,
                    yawDegrees: assessment.headYawDegrees,
                    pitchDegrees: assessment.headPitchDegrees,
                    isLooking: assessment.lookingAtScreen
                )
            } catch {
                // Fall through with the empty estimate.
            }
        }
        semaphore.wait()
        return result
    }
}
#endif
