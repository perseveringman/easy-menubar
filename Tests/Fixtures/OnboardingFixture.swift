import AppKit
import SwiftUI

extension Notification.Name {
    static let barFocusSearch = Notification.Name("BarFocusSearch")
    static let barRestoreMenuBarEntry = Notification.Name("BarRestoreMenuBarEntry")
}

/// Uses the shipping view with an unrefreshed model, so permission onboarding
/// can be inspected without revoking the installed app's real authorization.
@main
struct OnboardingFixture: App {
    @State private var model = StatusItemModel()
    var body: some Scene {
        Window("Bar · 首次使用验收", id: "onboarding-audit") {
            ContentView().environment(model)
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentMinSize)
    }
}
