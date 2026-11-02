import SwiftUI

/// 多选后的复制 / 移动操作模式。
enum PanTransferMode: String, Identifiable {
    case copy
    case move

    var id: String { rawValue }

    var actionTitle: String {
        switch self {
        case .copy: return "复制"
        case .move: return "移动"
        }
    }

    var systemImage: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.forward.folder"
        }
    }

    var busyText: String {
        "正在\(actionTitle)…"
    }
}

/// 复制 / 移动的目标目录选择：从根目录逐级进入，只列出文件夹。
struct PanFolderPickerView: View {
    let mode: PanTransferMode
    /// 确认目标目录后回调其 cid。
    let onPick: (String) -> Void

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var path: [Route] = []
    @State private var folders: [PanItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var createError: String?

    private let listSettings = FileListSettingsStore.shared

    private struct Route: Hashable {
        let cid: String
        let name: String
    }

    private var currentCid: String { path.last?.cid ?? "0" }
    private var currentTitle: String { path.last?.name ?? "根目录" }

    var body: some View {
        VStack(spacing: 0) {
            RexNavBar(
                title: "\(mode.actionTitle)到",
                leading: path.isEmpty
                    ? .text("取消", action: { dismiss() })
                    : .back(action: pop),
                actions: [
                    RexNavAction(
                        systemImage: "folder.badge.plus",
                        label: "新建文件夹",
                        action: { isCreatingFolder = true }
                    )
                ],
                isScrolled: false
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RexSpacing.md) {
                    Text("当前目录：\(currentTitle)")
                        .font(.system(size: 13))
                        .foregroundStyle(RexColor.secondaryText)
                        .lineLimit(1)

                    folderCard
                }
                .padding(.horizontal, RexSpacing.xl)
                .padding(.top, RexSpacing.md)
                .padding(.bottom, RexSpacing.huge)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            confirmBar
        }
        .background(RexColor.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") { Task { await createFolder() } }
        } message: {
            Text("在「\(currentTitle)」中创建")
        }
        .task(id: currentCid) {
            await load(currentCid)
        }
    }

    private func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private var folderCard: some View {
        VStack(spacing: 0) {
            if isLoading, folders.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RexSpacing.xxl)
            } else if let errorText {
                VStack(spacing: RexSpacing.sm) {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(RexColor.secondaryText)
                        .multilineTextAlignment(.center)

                    Button("重试") {
                        Task { await load(currentCid) }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RexColor.brandBlue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RexSpacing.xxl)
            } else if folders.isEmpty {
                Text("这里没有子文件夹")
                    .font(.system(size: 13))
                    .foregroundStyle(RexColor.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RexSpacing.xxl)
            } else {
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(RexColor.divider)
                            .frame(height: 1 / displayScale)
                            .padding(.leading, RexSpacing.lg + CGFloat(listSettings.iconSize) + RexSpacing.md)
                    }

                    folderRow(item)
                }
            }
        }
        .background(
            RexColor.surface,
            in: RoundedRectangle(cornerRadius: RexRadius.card, style: .continuous)
        )
    }

    private func folderRow(_ item: PanItem) -> some View {
        Button {
            path.append(Route(cid: item.id, name: item.name))
        } label: {
            HStack(spacing: RexSpacing.md) {
                // 与文件列表共用同一套文件夹图标，主题、尺寸保持一致。
                FileIconView(
                    kind: .folder,
                    theme: listSettings.folderTheme,
                    size: CGFloat(listSettings.iconSize)
                )

                Text(item.name)
                    .font(.system(size: 15))
                    .foregroundStyle(RexColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RexColor.secondaryText.opacity(0.45))
            }
            .padding(.horizontal, RexSpacing.lg)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("进入这个文件夹")
    }

    private var confirmBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RexColor.divider)
                .frame(height: 1 / displayScale)

            Button {
                onPick(currentCid)
                dismiss()
            } label: {
                Text("\(mode.actionTitle)到这里")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RexColor.brandBlue, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, RexSpacing.xl)
            .padding(.vertical, RexSpacing.md)
        }
        .background(RexColor.surface)
        .alert("新建文件夹失败", isPresented: createErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
    }

    private var createErrorBinding: Binding<Bool> {
        Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )
    }

    /// 在当前目录新建文件夹，成功后直接进入，方便立即确认复制 / 移动目标。
    @MainActor
    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty, let client = apiClient else { return }

        do {
            try await client.panCreateFolder(cid: currentCid, name: name)
            await load(currentCid)
            if let created = folders.first(where: { $0.isDir && $0.name == name }) {
                path.append(Route(cid: created.id, name: created.name))
            }
        } catch let error as APIError {
            guard error != .cancelled else { return }
            createError = error.errorDescription ?? "新建文件夹失败，请重试"
        } catch {
            createError = "新建文件夹失败，请重试"
        }
    }

    @MainActor
    private func load(_ cid: String) async {
        guard let client = apiClient else {
            errorText = "登录状态已失效，请重新登录"
            return
        }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            var all: [PanItem] = []
            var offset = 0
            // 只列文件夹，逐页取完，避免超过一页时漏掉后面的目录。
            while offset < 5_000 {
                let page = try await client.panList(cid: cid, offset: offset, limit: 200)
                all.append(contentsOf: page.items)
                offset = all.count
                if page.items.isEmpty || offset >= page.total { break }
            }
            folders = all.filter(\.isDir)
        } catch let error as APIError {
            guard error != .cancelled else { return }
            errorText = error.errorDescription ?? "目录加载失败"
        } catch {
            errorText = "目录加载失败"
        }
    }
}
