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
        }
    }
}

#Preview {
    NavigationStack {
        GestureSettingsView()
            .toolbar(.hidden, for: .navigationBar)
    }
}
