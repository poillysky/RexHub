import SwiftUI

/// 115 网盘账号页：展示服务端探测到的头像、VIP 与容量，并提供云下载入口。
/// App 不接触 Cookie，所有 115 请求由 NAS 后端转发。
struct PanAccountView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var account: PanAccount?
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        SettingsPage(title: "115 网盘") {
            switch phase {
            case .loading where account == nil:
                loadingCard
            case .failed(let message):
                failureCard(message)
            case .loading, .loaded:
                if let account, account.bound {
                    profileCard(account)
                    capacityCard(account)
                    if account.status == "invalid" {
                        warningCard(account.message)
                    }
                    actions
                } else {
                    unboundCard
                }
            }
        }
        .task {
            guard account == nil else { return }
            if let cached = PanAccountCache.fresh {
                account = cached
                phase = .loaded
                return
            }
            await load()
        }
    }

    // MARK: - 账号卡片

    private func profileCard(_ account: PanAccount) -> some View {
        VStack(alignment: .leading, spacing: RexSpacing.lg) {
            HStack(alignment: .top, spacing: RexSpacing.md) {
                avatar(account)

                VStack(alignment: .leading, spacing: RexSpacing.sm) {
                    Text(account.username.isEmpty ? "115 账号" : account.username)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: RexSpacing.sm) {
                        vipBadge(account)

                        if account.status != "invalid" {
                            boundBadge
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(height: 1)

            HStack(spacing: 0) {
                metric(icon: "internaldrive.fill", title: "已用空间", value: sizeText(account.used))

                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1, height: 32)
                    .padding(.horizontal, RexSpacing.lg)

                metric(icon: "externaldrive.fill", title: "网盘容量", value: sizeText(account.total))
            }
        }
        .padding(RexSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x4C9CFF), Color(hex: 0x1652D6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 150, height: 150)
                .offset(x: 50, y: -66)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 110, height: 110)
                .offset(x: -36, y: 44)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: RexRadius.panel, style: .continuous))
        .shadow(color: Color(hex: 0x1652D6).opacity(0.22), radius: 14, y: 8)
    }

    private func avatar(_ account: PanAccount) -> some View {
        AsyncImage(url: URL(string: account.avatar)) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Image("Brand115")
                .resizable()
                .scaledToFit()
                .padding(7)
                .background(.white.opacity(0.16))
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func vipBadge(_ account: PanAccount) -> some View {
        HStack(spacing: 5) {
            Image(systemName: account.vipActive ? "crown.fill" : "person.fill")
                .font(.system(size: 10, weight: .semibold))

            Text(vipText(account))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(account.vipActive ? Color(hex: 0x6B4700) : .white)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            Capsule().fill(
                account.vipActive
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [Color(hex: 0xFFE9B0), Color(hex: 0xFFC44D)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(Color.white.opacity(0.2))
            )
        }
    }

    private var boundBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .semibold))

            Text("已绑定")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.white.opacity(0.18), in: Capsule())
    }

    private func vipText(_ account: PanAccount) -> String {
        guard account.vipActive else { return "普通账号" }
        if account.vipForever { return "永久 VIP" }
        return account.vipExpire.isEmpty ? "VIP 会员" : "VIP 至 \(account.vipExpire)"
    }

    private func metric(icon: String, title: String, value: String) -> some View {
        HStack(spacing: RexSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))

                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 容量

    private func capacityCard(_ account: PanAccount) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: RexSpacing.lg) {
                HStack(spacing: RexSpacing.md) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(RexColor.brandBlue)
                        .frame(width: 40, height: 40)
                        .background(
                            RexColor.brandBlue.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("存储空间")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(RexColor.primaryText)

                        Text("\(sizeText(account.total)) 总容量")
                            .font(.system(size: 12))
                            .foregroundStyle(RexColor.secondaryText)
                    }

                    Spacer(minLength: RexSpacing.sm)

                    Text(percentText(account))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(RexColor.brandBlue)
                        .monospacedDigit()
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(RexColor.field)

                        Capsule()
                            .fill(RexColor.brandGradient)
                            .frame(width: max(6, proxy.size.width * fraction(account)))
                    }
                }
                .frame(height: 10)

                HStack(spacing: RexSpacing.md) {
                    legend(color: RexColor.brandBlue, title: "已用", value: sizeText(account.used))
                    legend(color: RexColor.divider, title: "剩余", value: sizeText(remaining(account)))
                }
            }
            .padding(RexSpacing.lg)
        }
    }

    private func legend(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RexColor.primaryText)
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fraction(_ account: PanAccount) -> CGFloat {
        guard let total = account.total, total > 0, let used = account.used else { return 0 }
        return min(1, max(0, CGFloat(used) / CGFloat(total)))
    }

    private func percentText(_ account: PanAccount) -> String {
        guard account.total != nil else { return "—" }
        return String(format: "%.1f%%", fraction(account) * 100)
    }

    private func remaining(_ account: PanAccount) -> Int64? {
        guard let total = account.total, let used = account.used else { return nil }
        return max(0, total - used)
    }

    private func sizeText(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    // MARK: - 操作

    private var actions: some View {
        SettingsSection(title: "快捷操作") {
            NavigationLink {
                PanCloudDownloadView()
            } label: {
                HStack(spacing: RexSpacing.md) {
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(
                            RexColor.brandGradient,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("云下载")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RexColor.primaryText)

                        Text("添加磁力 / HTTP 链接离线下载")
                            .font(.system(size: 12))
                            .foregroundStyle(RexColor.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: RexSpacing.sm)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RexColor.secondaryText.opacity(0.7))
                }
                .padding(.horizontal, RexSpacing.lg)
                .frame(height: 72)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    // MARK: - 状态卡

    private var loadingCard: some View {
        HStack(spacing: RexSpacing.sm) {
            ProgressView()
            Text("正在读取 115 账号…")
                .font(.system(size: 14))
                .foregroundStyle(RexColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RexSpacing.xxxl)
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
                .stroke(RexColor.divider, lineWidth: 1)
        )
    }

    private var unboundCard: some View {
        VStack(spacing: RexSpacing.lg) {
            Image("Brand115")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: 64, height: 64)
                .background(
                    RexColor.brandBlue.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                )

            Text("尚未绑定 115 网盘")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RexColor.primaryText)

            Text("请在 NAS 管理台完成扫码或 Cookie 绑定，绑定后这里会显示账号信息。")
                .font(.system(size: 13))
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

    private func warningCard(_ message: String) -> some View {
        HStack(spacing: RexSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(RexColor.warning)

            Text(message.isEmpty ? "115 授权已失效，请重新绑定" : message)
                .font(.system(size: 13))
                .foregroundStyle(RexColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(RexSpacing.lg)
        .background(
            RexColor.warning.opacity(0.1),
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private func failureCard(_ message: String) -> some View {
        VStack(spacing: RexSpacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(RexColor.warning)
                .frame(width: 64, height: 64)
                .background(
                    RexColor.warning.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: RexRadius.iconTile, style: .continuous)
                )

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(RexColor.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button {
                Task { await load() }
            } label: {
                Text("重试")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RexColor.onBrand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
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

    // MARK: - 数据

    private func load() async {
        guard let client = apiClient else {
            phase = .failed("登录状态已失效，请重新登录")
            return
        }

        phase = .loading
        do {
            let snapshot = try await client.panAccount()
            PanAccountCache.store(snapshot)
            account = snapshot
            phase = .loaded
        } catch let error as APIError {
            guard error != .cancelled else { return }
            phase = .failed(message(for: error))
        } catch {
            phase = .failed("读取账号信息失败，请重试")
        }
    }

    private func message(for error: APIError) -> String {
        if case .conflict(let detail) = error, let detail, !detail.isEmpty {
            return detail
        }
        return error.errorDescription ?? "读取账号信息失败，请重试"
    }
}

// MARK: - 账号缓存

/// 账号快照缓存：5 分钟内再次进入页面直接展示，避免每次 push 都等 115 接口。
private enum PanAccountCache {
    private static let ttl: TimeInterval = 300
    private static var account: PanAccount?
    private static var updatedAt = Date.distantPast

    static var fresh: PanAccount? {
        guard let account, Date().timeIntervalSince(updatedAt) < ttl else { return nil }
        return account
    }

    static func store(_ value: PanAccount) {
        account = value
        updatedAt = Date()
    }
}

// MARK: - 目录选择

struct PanFolder: Hashable, Identifiable {
    let cid: String
    let name: String

    var id: String { cid }
}

struct PanFolderPicker: View {
    @Binding var selected: PanFolder

    @Environment(\.dismiss) private var dismiss
    @State private var path: [PanFolder] = []

    var body: some View {
        NavigationStack(path: $path) {
            PanFolderList(folder: .init(cid: "0", name: "根目录")) { folder in
                selected = folder
                dismiss()
            }
            .navigationTitle("选择保存目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(for: PanFolder.self) { folder in
                PanFolderList(folder: folder) { picked in
                    selected = picked
                    dismiss()
                }
            }
        }
        .tint(RexColor.brandBlue)
    }
}

struct PanFolderList: View {
    let folder: PanFolder
    var onPick: (PanFolder) -> Void

    @Environment(\.apiClient) private var apiClient

    @State private var folders: [PanItem] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack(spacing: RexSpacing.sm) {
                        ProgressView()
                        Text("正在读取…")
                            .font(.system(size: 14))
                            .foregroundStyle(RexColor.secondaryText)
                    }
                } else if let errorText {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(RexColor.secondaryText)
                } else if folders.isEmpty {
                    Text("此目录下没有子文件夹")
                        .font(.system(size: 13))
                        .foregroundStyle(RexColor.secondaryText)
                } else {
                    ForEach(folders) { item in
                        NavigationLink(value: PanFolder(cid: item.id, name: item.name)) {
                            HStack(spacing: RexSpacing.md) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xF5B54A))
                                    .frame(width: 30, height: 30)
                                    .background(
                                        Color(hex: 0xF5B54A).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )

                                Text(item.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(RexColor.primaryText)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存到此目录") {
                    onPick(folder)
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.panList(cid: folder.cid, limit: 200)
            folders = page.items.filter(\.isDir)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorText = error.errorDescription ?? "读取目录失败"
        } catch {
            errorText = "读取目录失败"
        }
    }
}

#Preview {
    NavigationStack {
        PanAccountView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
