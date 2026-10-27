import SwiftUI
import MWDATCore

@main
struct GlassesStreamApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            print("Wearables.configure failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                    else { return }
                    Task {
                        try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}
