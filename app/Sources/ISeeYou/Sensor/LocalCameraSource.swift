import AVFoundation
import CoreImage
import Foundation

/// Fallback sensor: the Mac's built-in camera via AVFoundation.
/// No depth, but guarantees the demo runs on any Mac with zero hardware.
final class LocalCameraSource: NSObject, SensorSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let name = "Built-in Camera"
    var onFrame: ((SensorFrame) -> Void)?
    var onStatus: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "iseeyou.camera")
    private let ciContext = CIContext()
    private var lastFrameTime = Date.distantPast
    /// Vision + the state machine don't need more than ~10 fps.
    private let minFrameInterval: TimeInterval = 0.1

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.onStatus?("Camera access denied — grant it in System Settings → Privacy")
                return
            }
            self.queue.async { self.configureAndRun() }
        }
    }

    private func configureAndRun() {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onStatus?("No camera available")
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            onStatus?("Cannot attach video output")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        onStatus?("Built-in camera running")
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= minFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        onFrame?(SensorFrame(image: cgImage, depthMM: nil, timestamp: now))
    }
}
