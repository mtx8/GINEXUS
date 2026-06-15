// GinexusApp.swift — @main SwiftUI app entry (the GINEXUS head, tracer-bullet form).
import SwiftUI

@main
struct GinexusApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("GINEXUS") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
                .onDisappear { model.stop() }
        }
        .windowResizability(.contentMinSize)
    }
}
