// GinexusApp.swift — @main SwiftUI app entry. One hidden-titlebar window (Counterpart-family
// shell): content bleeds to the top edge; views compensate with their own top padding.
import SwiftUI

@main
struct GinexusApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("GINEXUS", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
                .onDisappear { model.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
