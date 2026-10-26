import SwiftUI
import MWDATCore

@main
struct GlassesStreamApp: App {
    init() {
        Wearables.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
