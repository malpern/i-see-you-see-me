import Foundation
import FoundationModels

/// Narrates the semantic event stream using Apple's on-device foundation model
/// (FoundationModels framework, macOS 26). Private, zero-cost, no network.
/// The narrator consumes ONLY semantic events — never frames — which is the
/// platform's privacy contract in action.
final class Narrator {
    enum Availability {
        case ready
        case unavailable(String)
    }

    var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return .unavailable(String(describing: reason))
        }
    }

    func narrate(events: [PresenceEvent], currentState: String) async throws -> String {
        let log = events.suffix(25).map { event -> String in
            var line = "\(Self.timeFormatter.string(from: event.timestamp)) \(event.kind.rawValue)"
            if let ms = event.durationMS { line += " (\(ms)ms)" }
            if let mm = event.distanceMM { line += " at \(mm)mm" }
            return line
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You summarize a presence sensor's event log. Events: arrivals, departures, \
            glances (brief looks), held attention, approach/recede. Respond with one or \
            two plain factual sentences stating what the person did and their current \
            state. Example: "Present for 5 minutes. Glanced at the screen twice, no \
            sustained attention." No opinions, no humor, no preamble, no emoji.
            """)

        let response = try await session.respond(to: """
            Current state: \(currentState)
            Event log (oldest first):
            \(log.isEmpty ? "(no events yet)" : log)
            """)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
