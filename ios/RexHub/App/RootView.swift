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

            case .connecting:
                ConnectingView(
                    isFailed: appState.connectionFailed,
                    onRetry: { Task { await appState.retryConnection() } },
                    onSignOut: { appState.signOut() }
                )
                .transition(.opacity)

            case .unauthenticated:
                LoginView()
                    .transition(.opacity)

            case .authenticated(let session):
                HomeView(session: session, isOffline: appState.isOffline) {
                    appState.signOut()
                }
                .environment(\.apiClient, appState.client)
                .overlay(alignment: .top) {
                    if appState.isOffline {
                        OfflineBanner()
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: appState.isOffline)
                .transition(.opacity)
            }
        }
        .background(KeyboardDismissInstaller())
        .animation(.easeOut(duration: 0.25), value: appState.phase)
        .task {
            await appState.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await appState.retryConnectionIfOffline() }
        }
        .alert("登录已过期", isPresented: sessionExpiredBinding) {
            Button("知道了", role: .cancel) { appState.acknowledgeSessionExpired() }
        } message: {
            Text(appState.sessionExpiredMessage ?? "")
        }
    }

    private var sessionExpiredBinding: Binding<Bool> {
        Binding(
            get: { appState.sessionExpiredMessage != nil },
            set: { if !$0 { appState.acknowledgeSessionExpired() } }
        )
    }
}

/// 断网时浮在内容上方的全局提示，网络恢复后自动收起。
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.warning)

            Text("网络已断开")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RexColor.primaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(RexColor.elevatedSurface)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(RexColor.cardBorder, lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
