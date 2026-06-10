import CoreGraphics
import Foundation

/// One observation from a sensor: a frame, optionally enriched with depth.
/// The sensor produces observations; it never interprets them.
struct SensorFrame {
    let image: CGImage
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
