import SwiftUI

/// 字幕设置：开关、外观与 HTTP 字幕源；播放页按配置自动拉取字幕。
struct SubtitleSettingsView: View {
    @Bindable private var settings = PlayerSettingsStore.shared

    @State private var isAddingSource = false
    @State private var draftSource = ""

    var body: some View {
        SettingsPage(
            title: "字幕",
            actions: [
                RexNavAction(systemImage: "plus", label: "添加字幕源") {
                    draftSource = ""
                    isAddingSource = true
                }
            ]
        ) {
            SettingsSection(title: "字幕") {
                SettingsSwitchRow(title: "自动加载字幕", isOn: $settings.subtitlesEnabled)

                SettingsDivider()

                SettingsMenuRow(
                    title: "默认语言",
                    options: SubtitleLanguage.allCases,
                    label: \.title,
                    selection: $settings.subtitleLanguage
                )
            }

            SettingsSection(title: "外观") {
                SettingsMenuRow(
                    title: "字幕字号",
                    options: SubtitleSize.allCases,
                    label: \.title,
                    selection: $settings.subtitleSize
                )

                SettingsDivider()

                SettingsSwitchRow(title: "半透明底色", isOn: $settings.subtitleBackground)
            }

            SettingsSection(title: "HTTP 字幕源") {
                if settings.subtitleSources.isEmpty {
                    SettingsRow(title: "尚未添加字幕源", value: "点击右上角 +")
                } else {
                    ForEach(Array(settings.subtitleSources.enumerated()), id: \.element) { index, source in
                        if index > 0 {
                            SettingsDivider()
                        }
                        sourceRow(source)
                    }
                }
            }

            Text("按顺序尝试字幕源，使用第一个能解析的结果。`{name}` 会替换成视频文件名（不含扩展名），`{lang}` 会替换成默认语言代码（如 zh、en），支持 SRT、VTT、ASS。字号即时作用于外部字幕，KSPlayer 内嵌字幕需下一次起播生效；半透明底色只作用于外部字幕。")
                .font(.system(size: 12))
                .foregroundStyle(RexColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RexSpacing.xs)
                .lineSpacing(2)
        }
        .alert("添加字幕源", isPresented: $isAddingSource) {
            TextField("https://example.com/sub/{name}.srt", text: $draftSource)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("取消", role: .cancel) {
                draftSource = ""
            }

            Button("添加") {
                settings.addSubtitleSource(draftSource)
                draftSource = ""
            }
        } message: {
            Text("填写返回字幕文件的 HTTP 地址，可包含 {name} 占位符。")
        }
    }

    private func sourceRow(_ source: String) -> some View {
        HStack(spacing: RexSpacing.md) {
            Text(source)
                .font(.system(size: 14))
                .foregroundStyle(RexColor.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)

            Spacer(minLength: RexSpacing.sm)

            Button {
                settings.removeSubtitleSource(source)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RexColor.error)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除字幕源")
        }
        .padding(.horizontal, RexSpacing.lg)
        .frame(minHeight: 56)
    }
}

#Preview {
    NavigationStack {
        SubtitleSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
