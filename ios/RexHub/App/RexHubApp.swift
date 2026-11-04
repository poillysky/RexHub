import SwiftUI

@main
struct RexHubApp: App {
    @State private var appState = AppState()
    @State private var theme = RexThemeStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(theme.appearance.colorScheme)
        }
    }
}
