import SwiftUI

@main
struct ISeeYouApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
                .onAppear { state.start() }
        } label: {
            Image(systemName: state.statusSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
