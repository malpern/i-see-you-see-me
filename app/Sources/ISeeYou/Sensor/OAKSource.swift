import CoreGraphics
import Foundation
import ImageIO

/// Primary sensor: the OAK-D Lite, reached over a local WebSocket served by
/// the Python DepthAI service (sensor/). Frames arrive as JSON:
///   { "type": "frame", "jpeg": "<base64>", "depth_mm": 850.0, "ts": 1718040000.0 }
/// Depth is the median stereo depth of the central ROI — the sensor ships
/// observations, never interpretations.
final class OAKSource: NSObject, SensorSource {
    let name = "OAK-D Lite"
    var onFrame: ((SensorFrame) -> Void)?
    var onStatus: ((String) -> Void)?

    private let url = URL(string: "ws://127.0.0.1:8765")!
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var reconnectAttempts = 0

    private struct FrameMessage: Decodable {
        let type: String
        let jpeg: String
        let depth_mm: Double?
    }

    func start() {
        running = true
        connect()
    }

    func stop() {
        running = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func connect() {
        guard running else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        onStatus?("Connecting to OAK-D service…")
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.running else { return }
            switch result {
            case .failure:
                self.onStatus?("OAK-D service unreachable — retrying…")
                self.scheduleReconnect()
            case .success(let message):
                self.reconnectAttempts = 0
                if case .string(let text) = message {
                    self.handle(text: text)
                }
                self.receive(on: task)
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(FrameMessage.self, from: data),
              msg.type == "frame",
              let jpegData = Data(base64Encoded: msg.jpeg),
              let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        onStatus?("OAK-D Lite streaming")
        onFrame?(SensorFrame(image: cgImage, depthMM: msg.depth_mm, timestamp: Date()))
    }

    private func scheduleReconnect() {
        guard running else { return }
        reconnectAttempts += 1
        let delay = min(5.0, Double(reconnectAttempts))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}
