import Foundation

/// Semantic events — the only thing consumers of the presence engine ever see.
/// No landmarks, no depth maps, no gaze vectors.
enum PresenceEventKind: String, Codable {
    case personEntered = "person_entered"
    case personLeft = "person_left"
    case lookStarted = "look_started"
    case lookEnded = "look_ended"
    case glance = "glance"
    case attentionHeld = "attention_held"
    case approaching = "approaching"
    case receding = "receding"
}

struct PresenceEvent: Identifiable, Codable {
    let id: UUID
    let kind: PresenceEventKind
    let timestamp: Date
    /// Duration of the look, for glance / attention_held / look_ended.
    var durationMS: Int?
    /// Subject distance in millimeters, when a depth-capable sensor is attached.
    var distanceMM: Int?

    init(_ kind: PresenceEventKind, durationMS: Int? = nil, distanceMM: Int? = nil) {
        self.id = UUID()
        self.kind = kind
        self.timestamp = Date()
        self.durationMS = durationMS
        self.distanceMM = distanceMM
    }

    var label: String {
        switch kind {
        case .personEntered: return "Person entered"
        case .personLeft: return "Person left"
        case .lookStarted: return "Look started"
        case .lookEnded: return "Look ended"
        case .glance: return "Glance"
        case .attentionHeld: return "Attention held"
        case .approaching: return "Approaching"
        case .receding: return "Receding"
        }
    }

    var symbolName: String {
        switch kind {
        case .personEntered: return "person.fill.checkmark"
        case .personLeft: return "person.fill.xmark"
        case .lookStarted: return "eye"
        case .lookEnded: return "eye.slash"
        case .glance: return "eye.trianglebadge.exclamationmark"
        case .attentionHeld: return "eye.circle.fill"
        case .approaching: return "arrow.down.forward.circle"
        case .receding: return "arrow.up.backward.circle"
        }
    }
}
