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

    /// OAK-D by default; a watchdog falls back to the built-in camera if no
    /// frames arrive, so the demo never opens on a dead sensor.
    @Published var sourceKind: SourceKind = .oak {
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
    /// Where the face is in the frame (normalized, Vision coords: y up).
    @Published private(set) var faceCenter: CGPoint?
    /// Increments on each detected blink (rising edge of eyes-closed).
    @Published private(set) var blinkCount = 0
    /// True while the person's eyes have stayed closed (~0.2s+), so the
    /// app's eyes can mirror sustained closure, not just blinks.
    @Published private(set) var personEyesClosed = false
    /// Discrete "big action" expressions — the only facial signals the eyes
    /// mirror. Subtle squints stay un-mirrored so the face keeps feeling
    /// autonomous rather than puppet-like.
    @Published private(set) var personWinkLeft = false
    @Published private(set) var personWinkRight = false
    @Published private(set) var personWide = false
    private var eyesWereClosed = false
    private var closedFrameStreak = 0
    private var winkLeftStreak = 0
    private var winkRightStreak = 0
    private var wideStreak = 0

    private var source: SensorSource?
    private let estimator: AttentionEstimator = VisionHeadPoseEstimator()
    private let engine = AttentionEngine()
    private let narrator = Narrator()
    private let processingQueue = DispatchQueue(label: "iseeyou.pipeline")
    private var narrationTask: Task<Void, Never>?
    private var eventsSinceNarration = 0
    private var started = false
    private var lastFrameAt = Date()
    private var watchdogTask: Task<Void, Never>?

    func start() {
        // Both the eyes window and the menu call this on appear.
        guard !started else { return }
        started = true
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.fallBackIfStarved()
            }
        }
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.append(event) }
        }
        if case .unavailable(let reason) = narrator.availability {
            narratorAvailable = false
            narration = "On-device model unavailable: \(reason)"
        }
        restartSensor()
    }

    /// If the OAK path goes quiet (service down, camera unplugged), switch
    /// to the built-in camera rather than sitting dark. Re-picking OAK-D in
    /// the menu retries it.
    private func fallBackIfStarved() {
        guard sourceKind == .oak, Date().timeIntervalSince(lastFrameAt) > 5 else { return }
        sourceKind = .builtIn
        sensorStatus = "OAK-D unavailable — fell back to built-in camera"
    }

    private func restartSensor() {
        lastFrameAt = Date()
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
            self.lastFrameAt = Date()
            self.engineState = self.engine.state
            if estimate.facePresent {
                self.lastYaw = estimate.yawDegrees
                self.lastPitch = estimate.pitchDegrees
                self.faceCenter = estimate.faceCenter
                if estimate.eyesClosed, !self.eyesWereClosed {
                    self.blinkCount += 1
                }
                self.eyesWereClosed = estimate.eyesClosed
                self.closedFrameStreak = estimate.eyesClosed ? self.closedFrameStreak + 1 : 0
                // ~3 frames at 15 fps: long enough to not be a blink.
                self.personEyesClosed = self.closedFrameStreak >= 3
                // Big-action detection with short streaks for stability:
                // a wink is one eye clearly shut while the other is clearly
                // open; wide is both well above relaxed, held a beat.
                if let l = estimate.leftEyeOpenness, let r = estimate.rightEyeOpenness {
                    self.winkLeftStreak = (l < 0.3 && r > 0.6) ? self.winkLeftStreak + 1 : 0
                    self.winkRightStreak = (r < 0.3 && l > 0.6) ? self.winkRightStreak + 1 : 0
                    self.wideStreak = ((l + r) / 2 > 1.18) ? self.wideStreak + 1 : 0
                    self.personWinkLeft = self.winkLeftStreak >= 2
                    self.personWinkRight = self.winkRightStreak >= 2
                    self.personWide = self.wideStreak >= 2
                }
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
