import SwiftUI

/// 服务管理：只读展示后端配置的 NAS 服务卡片与在线状态。
/// 凭据字段只在 Web 管理台维护，App 不保存账号与密钥。
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

                    Text("服务配置在 Web 管理台的「服务管理」中维护，App 只读展示，不保存账号与密钥。")
                        .font(.system(size: 12))
                        .foregroundStyle(RexColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, RexSpacing.xs)
                        .lineSpacing(2)
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
                isEnabled: phase != .loading
            ) {
                Task { await load() }
            }
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: RexSpacing.sm)

                Text(service.categoryLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RexColor.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RexColor.secondaryText.opacity(0.1), in: Capsule())
            }

            Text("\(service.host):\(service.port)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RexColor.secondaryText)
                .lineLimit(1)

            if !service.notes.isEmpty {
                Text(service.notes)
                    .font(.system(size: 12))
                    .foregroundStyle(RexColor.secondaryText.opacity(0.85))
                    .lineLimit(2)
            }

            statusTag(service)
        }
        .padding(RexSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .stroke(RexColor.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func statusTag(_ service: ServiceCard) -> some View {
        let color = statusColor(service)

        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)

            Text(statusText(service))
                .font(.system(size: 11, weight: .medium))
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
        HStack(spacing: RexSpacing.md) {
            ProgressView()

            Text("正在检测服务状态…")
                .font(.system(size: 14))
                .foregroundStyle(RexColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxxl)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private func failureCard(_ message: String) -> some View {
        VStack(spacing: RexSpacing.md) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(RexColor.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button {
                Task { await load() }
            } label: {
                Text("重试")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(width: 120, height: 38)
                    .background(
                        RexColor.brandGradient,
                        in: RoundedRectangle(cornerRadius: RexRadius.control, style: .continuous)
                    )
            }
            .buttonStyle(PressableButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxxl)
        .padding(.horizontal, RexSpacing.xl)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private var emptyCard: some View {
        VStack(spacing: RexSpacing.sm) {
            Image(systemName: "server.rack")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(RexColor.secondaryText.opacity(0.6))
                .padding(.bottom, RexSpacing.xs)

            Text("尚未添加服务")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RexColor.primaryText)

            Text("在 Web 管理台的「服务管理」中添加 NAS 服务后，这里会显示服务卡片。")
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxxl)
        .padding(.horizontal, RexSpacing.xl)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
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
