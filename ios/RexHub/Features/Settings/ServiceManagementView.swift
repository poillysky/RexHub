import SwiftUI

/// 服务管理：只读展示后端配置的 NAS 服务卡片与在线状态。
/// 凭据字段只在 PWA 设置中维护，App 不保存账号与密钥。
struct ServiceManagementView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var services: [ServiceCard] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        SettingsPage(title: "服务管理", actions: actions) {
            switch phase {
            case .loading where services.isEmpty:
                loadingCard
            case .failed(let message):
                failureCard(message)
            case .loading, .loaded:
                if services.isEmpty {
                    emptyCard
                } else {
                    VStack(spacing: RexSpacing.md) {
                        ForEach(services) { service in
                            card(service)
                        }
                    }

                    RexNote(text: "服务配置在 Web 端维护，App 只读展示，不保存账号与密钥。")
                }
            }
        }
        .task {
            guard services.isEmpty else { return }
            await load()
        }
    }

    private var actions: [RexNavAction] {
        [
            RexNavAction(
                systemImage: "arrow.clockwise",
                label: "刷新",
                isEnabled: phase != .loading,
                action: { Task { await load() } }
            )
        ]
    }

    // MARK: - 卡片

    private func card(_ service: ServiceCard) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.sm) {
            HStack(spacing: RexSpacing.sm) {
                Circle()
                    .fill(statusColor(service))
                    .frame(width: 8, height: 8)

                Text(service.name.isEmpty ? "未命名服务" : service.name)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: RexSpacing.sm)

                RexBadge(text: service.categoryLabel, tint: RexColor.secondaryText)
            }

            Text("\(service.host):\(service.port)")
                .font(RexFont.monoSmall)
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)

            if !service.notes.isEmpty {
                Text(service.notes)
                    .font(RexFont.caption)
                    .foregroundStyle(RexColor.secondaryText.opacity(0.85))
                    .lineLimit(2)
            }

            statusTag(service)
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
        .accessibilityElement(children: .combine)
    }

    private func statusTag(_ service: ServiceCard) -> some View {
        let color = statusColor(service)

        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)

            Text(statusText(service))
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(color.opacity(0.1), in: Capsule())
    }

    private func statusColor(_ service: ServiceCard) -> Color {
        switch service.online {
        case .some(true):
            return RexColor.success
        case .some(false):
            return RexColor.warning
        case .none:
            return RexColor.secondaryText
        }
    }

    private func statusText(_ service: ServiceCard) -> String {
        switch service.online {
        case .some(true):
            if let latency = service.latency {
                return "在线 · \(latency) ms"
            }
            return "在线"
        case .some(false):
            return "离线"
        case .none:
            return "未检测"
        }
    }

    // MARK: - 状态卡

    private var loadingCard: some View {
        RexStateCard(
            symbol: "server.rack",
            title: "正在检测服务状态",
            message: "稍候将展示 NAS 服务的在线情况。",
            tone: .brand,
            isLoading: true
        )
    }

    private func failureCard(_ message: String) -> some View {
        RexStateCard(
            symbol: "wifi.exclamationmark",
            title: "服务列表加载失败",
            message: message,
            tone: .warning,
            actionTitle: "重试"
        ) {
            RexHaptics.tap()
            Task { await load() }
        }
    }

    private var emptyCard: some View {
        RexStateCard(
            symbol: "server.rack",
            title: "尚未添加服务",
            message: "在 Web 端配置 NAS 服务后，这里会显示服务卡片。",
            tone: .neutral
        )
    }

    // MARK: - 数据

    private func load() async {
        phase = .loading

        guard let client = apiClient else {
            phase = .failed("登录状态已失效，请重新登录")
            return
        }

        do {
            services = try await client.serviceList()
            phase = .loaded
        } catch let error as APIError {
            guard error != .cancelled else { return }
            phase = .failed(error.errorDescription ?? "服务列表加载失败，请重试")
        } catch {
            phase = .failed("服务列表加载失败，请重试")
        }
    }
}
