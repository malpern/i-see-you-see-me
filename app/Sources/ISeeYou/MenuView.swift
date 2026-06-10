import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            narrationCard
            Divider()
            eventFeed
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.statusSymbol)
                .font(.title2)
                .foregroundStyle(state.engineState == .looking ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.engineState.rawValue)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(state.sensorStatus)
                    if state.engineState != .empty {
                        Text(String(format: "yaw %.0f° · pitch %.0f°", state.lastYaw, state.lastPitch))
                    }
                    if let mm = state.lastDistanceMM {
                        Text(String(format: "%.1fm", Double(mm) / 1000))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var narrationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("On-device narration", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Narrate") { state.narrateNow() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!state.narratorAvailable)
            }
            Text(state.narration)
                .font(.callout.italic())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.events.isEmpty {
                Text("No events yet — step into frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.events.prefix(8)) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.symbolName)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(event.label)
                        .font(.callout)
                    if let ms = event.durationMS {
                        Text("\(String(format: "%.1f", Double(ms) / 1000))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Picker("Sensor", selection: $state.sourceKind) {
                ForEach(AppState.SourceKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .font(.caption)
        }
    }
}
