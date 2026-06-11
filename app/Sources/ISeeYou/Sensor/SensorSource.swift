import CoreGraphics
import CoreVideo
import Foundation

/// One observation from a sensor: a frame, optionally enriched with depth.
/// The sensor produces observations; it never interprets them.
/// Frames carry their native representation — converting pixel buffers to
/// CGImage 15x/s costs a full-frame render + allocation each time, and
/// Vision consumes both directly.
struct SensorFrame {
    enum Payload {
        case pixelBuffer(CVPixelBuffer)
        case cgImage(CGImage)
    }

    let payload: Payload
    /// Median depth of the central region in millimeters (depth sensors only).
    let depthMM: Double?
    let timestamp: Date
}

/// A swappable observation producer. The OAK-D Lite is the primary source;
/// the built-in camera is the zero-dependency fallback so the demo never dies.
protocol SensorSource: AnyObject {
    var name: String { get }
    var onFrame: ((SensorFrame) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
}
