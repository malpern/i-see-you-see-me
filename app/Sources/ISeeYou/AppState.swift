import AVFoundation
import Foundation
import SwiftUI

/// How the eyes are drawn.
enum EyeStyle: String, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"
    case round = "Round"
    var id: String { rawValue }
}

/// Wires sensor → estimator → engine → UI, and owns the narration loop.
@MainActor
final class AppState: ObservableObject {
    /// Eye rendering style, persisted.
    @Published var eyeStyle: EyeStyle = EyeStyle(
        rawValue: UserDefaults.standard.string(forKey: "eyeStyle") ?? ""
    ) ?? .male {
        didSet { UserDefaults.standard.set(eyeStyle.rawValue, forKey: "eyeStyle") }
    }
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
    @Published private(set) var personWide = false
    private var eyesWereClosed = false
    private var closedFrameStreak = 0
    private var wideStreak = 0

    /// How tightly "looking at you" is scored: 0 = relaxed (±30° head cone),
    /// 1 = strict (±8°). Applied to the estimator live, persisted.
    @Published var gazeStrictness: Double = UserDefaults.standard.object(forKey: "gazeStrictness") as? Double ?? 0.6 {
        didSet {
            UserDefaults.standard.set(gazeStrictness, forKey: "gazeStrictness")
            applyGazeStrictness()
        }
    }

    /// Yaw half-angle (degrees) for the current strictness; shown in the UI.
    var gazeConeDegrees: Double { 30.0 - gazeStrictness * 22.0 }

    private var source: SensorSource?
    // Accessed from the serial processing queue; threshold writes from the
    // main actor are benign (plain doubles, single reader).
    private nonisolated(unsafe) let visionEstimator = VisionHeadPoseEstimator()
    private nonisolated var estimator: AttentionEstimator { visionEstimator }
    private let engine = AttentionEngine()
    private let narrator = Narrator()
    private let processingQueue = DispatchQueue(label: "iseeyou.pipeline")
    private var narrationTask: Task<Void, Never>?
    private var eventsSinceNarration = 0
    private var started = false
    private var lastFrameAt = Date()
    private var watchdogTask: Task<Void, Never>?

    private func applyGazeStrictness() {
        visionEstimator.yawThresholdDegrees = gazeConeDegrees
        visionEstimator.pitchThresholdDegrees = gazeConeDegrees * 0.8
        // One concept, one control: a stricter cone also means a snappier
        // look-end — relaxed 0.9s down to 0.25s at full strict.
        engine.lookEndDebounce = 0.9 - gazeStrictness * 0.65
    }

    func start() {
        // Both the eyes window and the menu call this on appear.
        guard !started else { return }
        started = true
        applyGazeStrictness()
        watchdogTask = Task { [weak self] in
            var probeCountdown = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.fallBackIfStarved()
                // OAK is the preferred sensor: while on the fallback, probe
                // every ~8s and climb back the moment it delivers frames.
                if self.sourceKind == .builtIn {
                    probeCountdown -= 1
                    if probeCountdown <= 0 {
                        probeCountdown = 4
                        if await Self.oakIsDelivering() {
                            self.sourceKind = .oak
                            self.sensorStatus = "OAK-D back — switching over"
                        }
                    }
                }
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

    /// True when the OAK service is up AND sending frames (a listening port
    /// with no camera attached doesn't count).
    private nonisolated static func oakIsDelivering() async -> Bool {
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8765")!)
        ws.maximumMessageSize = 4 * 1024 * 1024
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await ws.receive()) != nil }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
                // Big-action detection with a short streak for stability:
                // wide is both eyes well above relaxed, held a beat.
                if let l = estimate.leftEyeOpenness, let r = estimate.rightEyeOpenness {
                    self.wideStreak = ((l + r) / 2 > 1.18) ? self.wideStreak + 1 : 0
                    self.personWide = self.wideStreak >= 2
                }
            }
            if let depth = frame.depthMM { self.lastDistanceMM = Int(depth) }
        }
    }

    // Acknowledgment vocalizations: a quiet "mhh" when eye contact begins.
    private var ackPlayer: AVAudioPlayer?
    private var lastAckAt = Date.distantPast

    /// Male eyes only; at most one sound per 10s no matter how often the
    /// look state flips.
    private func playAcknowledgmentIfDue() {
        guard eyeStyle == .male else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAckAt) >= 10 else { return }
        guard let url = Bundle.main.url(forResource: "mhh\(Int.random(in: 1...4))", withExtension: "wav") else { return }
        lastAckAt = now
        ackPlayer = try? AVAudioPlayer(contentsOf: url)
        ackPlayer?.play()
    }

    private func append(_ event: PresenceEvent) {
        if event.kind == .lookStarted { playAcknowledgmentIfDue() }
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
