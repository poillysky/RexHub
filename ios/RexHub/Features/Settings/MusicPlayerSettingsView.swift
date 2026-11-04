import SwiftUI

/// 音乐播放器偏好：进入播放页前决定的播放范围与默认参数。
struct MusicPlayerSettingsView: View {
    @Bindable private var settings = MusicSettingsStore.shared

    var body: some View {
        SettingsPage(title: "音乐播放器") {
            SettingsSection(title: "播放列表模式") {
                SettingsMenuRow(
                    title: "模式",
                    options: MusicPlaylistMode.allCases,
                    label: \.title,
                    selection: $settings.playlistMode
                )
            }

            RexNote(text: settings.playlistMode.summary)
                .lineSpacing(2)

            SettingsSection(title: "外观") {
                SettingsSwitchRow(title: "模糊封面背景", isOn: $settings.blurCover)
            }

            SettingsSection(title: "播放") {
                SettingsStepperRow(
                    title: "快退秒数",
                    value: $settings.rewindSeconds,
                    range: 5...60,
                    step: 5
                )

                SettingsDivider()

                SettingsStepperRow(
                    title: "快进秒数",
                    value: $settings.forwardSeconds,
                    range: 5...60,
                    step: 5
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "播放速度",
                    options: MusicSettingsStore.playbackRates,
                    label: PlayerSettingsStore.rateText,
                    selection: $settings.playbackRate
                )
            }

            RexNote(text: "音乐播放器按当前目录顺序播放音频文件，快退、快进与倍速只影响音乐播放器。")
                .lineSpacing(2)
        }
    }
}

#Preview {
    NavigationStack {
        MusicPlayerSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
