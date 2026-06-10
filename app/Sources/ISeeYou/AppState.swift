import Foundation
import SwiftUI

/// Wires sensor → estimator → engine → UI, and owns the narration loop.
@MainActor
final class AppState: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case oak = "OAK-D Lite"
        case builtIn = "Built-in Camera"
        var id: String { rawValue }
    }

    @Published var sourceKind: SourceKind = .builtIn {
        didSet { if oldValue != sourceKind { restartSensor() } }
    }
    @Published private(set) var engineState: AttentionEngine.State = .empty
    @Published private(set) var events: [PresenceEvent] = []
    @Published private(set) var sensorStatus = "Starting…"
    @Published private(set) var narration = "Waiting for something to narrate…"
    @Published private(set) var narratorAvailable = true
    @Published private(set) var lastYaw: Double = 0
    @Published private(set) var lastPitch: Double = 0
    @Published private(set) var lastDistanceMM: Int?

    private var source: SensorSource?
    private let estimator: AttentionEstimator = VisionHeadPoseEstimator()
    private let engine = AttentionEngine()
    private let narrator = Narrator()
    private let processingQueue = DispatchQueue(label: "iseeyou.pipeline")
    private var narrationTask: Task<Void, Never>?
    private var eventsSinceNarration = 0
    private var started = false

    func start() {
        // Both the eyes window and the menu call this on appear.
        guard !started else { return }
        started = true
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.append(event) }
        }
        if case .unavailable(let reason) = narrator.availability {
            narratorAvailable = false
            narration = "On-device model unavailable: \(reason)"
        }
        restartSensor()
    }

    private func restartSensor() {
        source?.stop()
        let newSource: SensorSource = sourceKind == .oak ? OAKSource() : LocalCameraSource()
        source = newSource
        sensorStatus = "Starting \(newSource.name)…"
        newSource.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.sensorStatus = status }
        }
        newSource.onFrame = { [weak self] frame in
            self?.processingQueue.async { self?.process(frame) }
        }
        newSource.start()
    }

    nonisolated private func process(_ frame: SensorFrame) {
        let estimate = estimator.estimate(from: frame)
        engine.update(estimate, depthMM: frame.depthMM)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engineState = self.engine.state
            if estimate.facePresent {
                self.lastYaw = estimate.yawDegrees
                self.lastPitch = estimate.pitchDegrees
            }
            if let depth = frame.depthMM { self.lastDistanceMM = Int(depth) }
        }
    }

    private func append(_ event: PresenceEvent) {
        events.insert(event, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
        eventsSinceNarration += 1
        // Narrate after a couple of fresh events, never concurrently.
        if narratorAvailable, eventsSinceNarration >= 2, narrationTask == nil {
            eventsSinceNarration = 0
            narrationTask = Task { [weak self] in
                await self?.runNarration()
                self?.narrationTask = nil
            }
        }
    }

    func narrateNow() {
        guard narratorAvailable, narrationTask == nil else { return }
        narrationTask = Task { [weak self] in
            await self?.runNarration()
            self?.narrationTask = nil
        }
    }

    private func runNarration() async {
        let snapshot = events.reversed().map { $0 }
        let state = engineState.rawValue
        do {
            narration = try await narrator.narrate(events: snapshot, currentState: state)
        } catch {
            narration = "Narration failed: \(error.localizedDescription)"
        }
    }

    var statusSymbol: String {
        switch engineState {
        case .empty: return "eye.slash"
        case .present: return "person.fill"
        case .looking: return "eye.fill"
        }
    }
}
