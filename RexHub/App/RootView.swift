import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch appState.phase {
            case .launching:
                SplashView()
                    .transition(.opacity)

            case .unauthenticated:
                LoginView()
                    .transition(.opacity)

            case .authenticated(let session):
                HomeView(session: session, isOffline: appState.isOffline) {
                    appState.signOut()
                }
                .environment(\.apiClient, appState.client)
                .transition(.opacity)
            }
        }
        .background(KeyboardDismissInstaller())
        .animation(.easeInOut(duration: 0.35), value: appState.phase)
        .task {
            await appState.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await appState.retryConnectionIfOffline() }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
