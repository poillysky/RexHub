import SwiftUI

/// 手势设置：单指手势逐项绑定动作，参考常见播放器的分区手势模型。
struct GestureSettingsView: View {
    @Bindable private var settings = GestureSettingsStore.shared

    var body: some View {
        SettingsPage(title: "手势") {
            SettingsSection(title: "单指手势") {
                SettingsMenuRow(
                    title: "单击",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.singleTap
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "双击中间",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.doubleTapCenter
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "双击左侧 1/4",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.doubleTapLeft
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "双击右侧 1/4",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.doubleTapRight
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "长按",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.longPress
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "左右拖动",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.horizontalDrag
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "左侧上下拖动",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.leftVerticalDrag
                )

                SettingsDivider()

                SettingsMenuRow(
                    title: "右侧上下拖动",
                    options: GestureAction.allCases,
                    label: \.title,
                    selection: $settings.rightVerticalDrag
                )
            }

            RexNote(text: "手势统一由播放页控制层处理，AVPlayer 与 KSPlayer 内核都生效。双击左右区域默认与中间一致，改成快退/快进即可获得分区跳转；拖动查找、亮度与音量按手势起点所在位置判断。")
                .lineSpacing(2)
        }
    }
}

#Preview {
    NavigationStack {
        GestureSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
