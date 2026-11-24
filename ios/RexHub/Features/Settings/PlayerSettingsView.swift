import SwiftUI

/// 视频播放器：固定 KSPlayer 直链播放，只保留会改变观看体验的配置。
struct VideoPlayerSettingsView: View {
    @Bindable private var settings = PlayerSettingsStore.shared

    var body: some View {
        SettingsPage(title: "视频播放器") {
            SettingsSection(title: "播放") {
                SettingsSwitchRow(title: "自动播放", isOn: $settings.autoPlay)

                SettingsDivider()

                SettingsMenuRow(
                    title: "默认倍速",
                    options: PlayerSettingsStore.playbackRates,
                    label: PlayerSettingsStore.rateText,
                    selection: $settings.playbackRate
                )

                SettingsDivider()

                SettingsSwitchRow(title: "变速保持音调", isOn: $settings.keepPitch)
            }

            SettingsSection(title: "起播与缓冲") {
                SettingsMenuRow(
                    title: "缓冲策略",
                    options: PlayerBufferPolicy.allCases,
                    label: \.title,
                    selection: $settings.bufferPolicy
                )
            }

            SettingsSection(title: "结束与续播") {
                SettingsSwitchRow(title: "记住播放进度", isOn: $settings.resumePlayback)

                SettingsDivider()

                SettingsSwitchRow(title: "自动连播下一集", isOn: $settings.autoPlayNext)
            }

            SettingsSection(title: "后台与屏幕") {
                SettingsSwitchRow(title: "后台播放音频", isOn: $settings.backgroundAudio)

                SettingsDivider()

                SettingsSwitchRow(title: "屏幕常亮", isOn: $settings.keepScreenAwake)

                SettingsDivider()

                SettingsSwitchRow(title: "自动横屏", isOn: $settings.autoLandscape)
            }

            SettingsSection(title: "跳过片头片尾") {
                SettingsSwitchRow(title: "跳过片头", isOn: $settings.skipIntro)

                if settings.skipIntro {
                    SettingsDivider()

                    SettingsStepperRow(title: "片头时长", value: $settings.introSeconds)
                }

                SettingsDivider()

                SettingsSwitchRow(title: "跳过片尾", isOn: $settings.skipOutro)

                if settings.skipOutro {
                    SettingsDivider()

                    SettingsStepperRow(title: "片尾时长", value: $settings.outroSeconds)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        VideoPlayerSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
