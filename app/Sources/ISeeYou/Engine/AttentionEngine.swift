import Foundation

/// Interpretation layer: turns per-frame estimates into semantic events with
/// hysteresis and dwell timers. Pure logic — no Vision, no camera, no UI —
/// so it's unit-testable and sensor-agnostic.
final class AttentionEngine {
    enum State: String {
        case empty = "No one here"
        case present = "Present"
        case looking = "Looking"
    }

    // Tunables (seconds).
    var enterDebounce: TimeInterval = 0.4
    var leaveDebounce: TimeInterval = 1.5
    var lookStartDebounce: TimeInterval = 0.25
    var lookEndDebounce: TimeInterval = 0.7
    /// A finished look shorter than this is a glance…
    var glanceMax: TimeInterval = 1.2
    /// …and an ongoing look longer than this is held attention.
    var attentionHeldThreshold: TimeInterval = 3.0
    /// Depth change (mm) over the trend window that counts as moving.
    var approachThresholdMM: Double = 250

    private(set) var state: State = .empty
    var onEvent: ((PresenceEvent) -> Void)?

    // Hysteresis bookkeeping.
    private var faceSeenSince: Date?
    private var faceGoneSince: Date?
    private var lookingSince: Date?
    private var notLookingSince: Date?
    private var lookBeganAt: Date?
    private var attentionHeldFired = false
    private var lastDistanceMM: Double?
    private var depthSamples: [(Date, Double)] = []
    private var lastMotionEvent: PresenceEventKind?

    func update(_ estimate: AttentionEstimate, depthMM: Double?, at now: Date = Date()) {
        if let depthMM { lastDistanceMM = depthMM }
        updatePresence(estimate.facePresent, at: now)
        if state != .empty {
            updateLooking(estimate.facePresent && estimate.isLooking, at: now)
            if let depthMM { updateMotion(depthMM, at: now) }
        }
    }

    private func emit(_ kind: PresenceEventKind, durationMS: Int? = nil) {
        var event = PresenceEvent(kind, durationMS: durationMS)
        event.distanceMM = lastDistanceMM.map { Int($0) }
        onEvent?(event)
    }

    private func updatePresence(_ facePresent: Bool, at now: Date) {
        if facePresent {
            faceGoneSince = nil
            if faceSeenSince == nil { faceSeenSince = now }
            if state == .empty, now.timeIntervalSince(faceSeenSince!) >= enterDebounce {
                state = .present
                emit(.personEntered)
            }
        } else {
            faceSeenSince = nil
            if faceGoneSince == nil { faceGoneSince = now }
            if state != .empty, now.timeIntervalSince(faceGoneSince!) >= leaveDebounce {
                endLookIfNeeded(at: faceGoneSince!)
                state = .empty
                depthSamples.removeAll()
                lastMotionEvent = nil
                emit(.personLeft)
            }
        }
    }

    private func updateLooking(_ isLooking: Bool, at now: Date) {
        if isLooking {
            notLookingSince = nil
            if lookingSince == nil { lookingSince = now }
            if state == .present, now.timeIntervalSince(lookingSince!) >= lookStartDebounce {
                state = .looking
                lookBeganAt = lookingSince
                attentionHeldFired = false
                emit(.lookStarted)
            }
            if state == .looking, !attentionHeldFired, let began = lookBeganAt,
               now.timeIntervalSince(began) >= attentionHeldThreshold {
                attentionHeldFired = true
                emit(.attentionHeld, durationMS: Int(now.timeIntervalSince(began) * 1000))
            }
        } else {
            lookingSince = nil
            if notLookingSince == nil { notLookingSince = now }
            if state == .looking, now.timeIntervalSince(notLookingSince!) >= lookEndDebounce {
                endLookIfNeeded(at: notLookingSince!)
                state = .present
            }
        }
    }

    private func endLookIfNeeded(at end: Date) {
        guard state == .looking, let began = lookBeganAt else { return }
        let duration = end.timeIntervalSince(began)
        let ms = Int(duration * 1000)
        if duration <= glanceMax {
            emit(.glance, durationMS: ms)
        } else {
            emit(.lookEnded, durationMS: ms)
        }
        lookBeganAt = nil
        attentionHeldFired = false
    }

    private func updateMotion(_ depthMM: Double, at now: Date) {
        depthSamples.append((now, depthMM))
        depthSamples.removeAll { now.timeIntervalSince($0.0) > 2.0 }
        guard let oldest = depthSamples.first, depthSamples.count >= 5 else { return }
        let delta = depthMM - oldest.1
        if delta <= -approachThresholdMM, lastMotionEvent != .approaching {
            lastMotionEvent = .approaching
            emit(.approaching)
            depthSamples = [(now, depthMM)]
        } else if delta >= approachThresholdMM, lastMotionEvent != .receding {
            lastMotionEvent = .receding
            emit(.receding)
            depthSamples = [(now, depthMM)]
        }
    }
}
