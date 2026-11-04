import SwiftUI

/// 视频播放器：内核、解码与起播参数，能生效的直接作用于 AVPlayer，修改即落盘。
struct VideoPlayerSettingsView: View {
    @Bindable private var settings = PlayerSettingsStore.shared

    var body: some View {
        SettingsPage(title: "视频播放器") {
            SettingsSection(title: "内核与解码") {
                SettingsMenuRow(
                    title: "播放内核",
                    options: PlayerKernel.allCases,
                    label: \.title,
                    selection: $settings.kernel
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "解码方式",
                    options: PlayerDecodeMode.allCases,
                    label: \.title,
                    selection: $settings.decodeMode
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "起播清晰度",
                    options: PlayerResolution.allCases,
                    label: \.title,
                    selection: $settings.preferredResolution
                )
            }

            SettingsSection(title: "起播与缓冲") {
                SettingsMenuRow(
                    title: "缓冲策略",
                    options: PlayerBufferPolicy.allCases,
                    label: \.title,
                    selection: $settings.bufferPolicy
                )

                SettingsDivider()

                SettingsSwitchRow(title: "自动等待缓冲", isOn: $settings.waitMinimizeStalling)
            }

            RexNote(text: settings.kernel.summary)
            RexNote(text: "切换内核后下一次起播生效；解码方式只作用于 KSPlayer 内核，起播清晰度只对多码率 HLS 生效，115 单文件直链按原片播放。")
        }
    }
}

/// 播放偏好：起播、倍速、结束行为、后台与片头片尾，下一次起播时应用。
struct PlaybackPreferenceView: View {
    @Bindable private var settings = PlayerSettingsStore.shared

    var body: some View {
        SettingsPage(title: "播放偏好") {
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

                SettingsDivider()

                SettingsSwitchRow(title: "静音起播", isOn: $settings.startMuted)
            }

            SettingsSection(title: "结束与续播") {
                SettingsSwitchRow(title: "记住播放进度", isOn: $settings.resumePlayback)

                SettingsDivider()

                SettingsSwitchRow(title: "自动连播下一集", isOn: $settings.autoPlayNext)

                SettingsDivider()

                SettingsSwitchRow(title: "播放结束自动关闭", isOn: $settings.autoCloseOnFinish)

                SettingsDivider()

                SettingsSwitchRow(title: "循环播放", isOn: $settings.loopPlayback)
            }

            SettingsSection(title: "后台与屏幕") {
                SettingsSwitchRow(title: "后台播放音频", isOn: $settings.backgroundAudio)

                SettingsDivider()

                SettingsSwitchRow(title: "屏幕常亮", isOn: $settings.keepScreenAwake)

                SettingsDivider()

                SettingsSwitchRow(title: "自动横屏", isOn: $settings.autoLandscape)

                SettingsDivider()

                SettingsSwitchRow(title: "记忆音量", isOn: $settings.rememberVolume)

                SettingsDivider()

                SettingsSwitchRow(title: "记忆亮度", isOn: $settings.rememberBrightness)
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

            RexNote(text: "跳过片头只在没有续播进度时生效，有进度时以进度为准；跳过片尾会在剩余时间不足设定秒数时直接结束，并配合「播放结束自动关闭」退出播放页。循环播放优先于自动关闭。")
            RexNote(text: "开启后台播放音频后，锁屏或退到后台仍会继续出声；关闭则退到后台立即暂停。修改后在下一次起播时生效。")
            RexNote(text: "开启自动横屏后，进入视频播放页会直接转为横屏，退出播放页恢复竖屏；播放器里的全屏按钮仍可手动切换方向。")
            RexNote(text: "变速保持音调与自动等待缓冲由 AVPlayer 内核执行，KSPlayer 按自身解码策略播放；其余开关对两个内核都生效。")
        }
    }
}

#Preview {
    NavigationStack {
        PlaybackPreferenceView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
