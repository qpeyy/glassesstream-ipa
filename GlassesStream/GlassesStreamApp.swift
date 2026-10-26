import SwiftUI
import MWDATCore

@main
struct GlassesStreamApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            print("Wearables configure failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
