import SwiftUI

@main
struct ISeeYouApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // First scene → opens at launch: the eyes.
        Window("I See You", id: "eyes") {
            EyesView(state: state)
                .frame(minWidth: 380, minHeight: 240)
        }
        .defaultSize(width: 540, height: 320)

        MenuBarExtra {
            MenuView(state: state)
                .onAppear { state.start() }
        } label: {
            Image(systemName: state.statusSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
