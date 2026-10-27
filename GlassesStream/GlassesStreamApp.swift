import SwiftUI
import MWDATCore

@main
struct GlassesStreamApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            GlassesManager.configureError = "\(error)"
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GlassesManager.shared.handleURL(url)
                }
        }
    }
}
