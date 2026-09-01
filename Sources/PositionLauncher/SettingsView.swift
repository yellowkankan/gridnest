import SwiftUI

struct SettingsActions {
    let setDock: (Bool) -> Void
    let setMenuBar: (Bool) -> Void
    let setHotkey: (Bool) -> Void
    let setHotkeyStyle: (String) -> Void
    let reloadLayout: () -> Void
    let pageCount: () -> Int
    let selectAppIcon: () -> Void
    let resetAppIcon: () -> Void
}

struct SettingsView: View {
    let actions: SettingsActions

    @AppStorage("showDock") private var showDock = true
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = true
    @AppStorage("hotkeyStyle") private var hotkeyStyle = "controlOptionL"
    @AppStorage("iconSize") private var iconSize = 92.0
    @AppStorage("columns") private var columns = 7
    @AppStorage("rows") private var rows = 5
    @AppStorage("swipeReversed") private var swipeReversed = true
    @AppStorage("defaultPage") private var defaultPage = 0
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("backgroundStyle") private var backgroundStyle = "glass"
    @AppStorage("backgroundStrength") private var backgroundStrength = 0.68
    @AppStorage("showAppLabels") private var showAppLabels = true
    @AppStorage("labelFontSize") private var labelFontSize = 13.0
    @AppStorage("labelWeight") private var labelWeight = "medium"
    @AppStorage("pageAnimationDuration") private var pageAnimationDuration = 0.58

    private var lastPageIndex: Int { Swift.max(0, actions.pageCount() - 1) }

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
            appearanceSettings
                .tabItem { Label("外观与行为", systemImage: "paintbrush") }
        }
        .frame(width: 530, height: 580)
    }

    private var generalSettings: some View {
        Form {
            Section("显示") {
                Toggle("在程序坞显示图标", isOn: $showDock)
                    .onChange(of: showDock) { actions.setDock(showDock) }
                Toggle("在菜单栏显示图标", isOn: $showMenuBar)
                    .onChange(of: showMenuBar) { actions.setMenuBar(showMenuBar) }
            }

            Section("网格") {
                HStack {
                    Text("图标大小")
                    Slider(value: $iconSize, in: 48...112, step: 2)
                        .onChange(of: iconSize) { actions.reloadLayout() }
                    Text("\(Int(iconSize))").monospacedDigit().foregroundStyle(.secondary)
                }
                Stepper("每行图标：\(columns)", value: $columns, in: 4...10)
                    .onChange(of: columns) { actions.reloadLayout() }
                Stepper("每页行数：\(rows)", value: $rows, in: 3...8)
                    .onChange(of: rows) { actions.reloadLayout() }
            }

            Section("翻页") {
                Toggle("反转双指滑动方向", isOn: $swipeReversed)
                Stepper("默认打开第 \(Swift.min(defaultPage, lastPageIndex) + 1) 页", value: $defaultPage, in: 0...lastPageIndex)
            }

            Section("唤出方式") {
                Toggle("启用全局快捷键", isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { actions.setHotkey(hotkeyEnabled) }
                Picker("快捷键", selection: $hotkeyStyle) {
                    Text("⌃⌥L").tag("controlOptionL")
                    Text("F4").tag("f4")
                }
                .disabled(!hotkeyEnabled)
                .onChange(of: hotkeyStyle) { actions.setHotkeyStyle(hotkeyStyle) }
                Text("若 F4 无效，请在 macOS 键盘设置中关闭“将 F1、F2 等键用作标准功能键”，或改用 ⌃⌥L。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("恢复默认设置", role: .destructive) { restoreDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            Section("外观模式") {
                Picker("模式", selection: $appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("背景") {
                Picker("背景样式", selection: $backgroundStyle) {
                    Text("液态玻璃").tag("glass")
                    Text("柔和模糊").tag("soft")
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("背景强度")
                    Slider(value: $backgroundStrength, in: 0.35...0.90, step: 0.01)
                    Text("\(Int(backgroundStrength * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Section("图标文字") {
                Toggle("显示应用名称", isOn: $showAppLabels)
                HStack {
                    Text("字号")
                    Slider(value: $labelFontSize, in: 10...18, step: 1)
                    Text("\(Int(labelFontSize))").monospacedDigit().foregroundStyle(.secondary)
                }
                .disabled(!showAppLabels)
                Picker("字重", selection: $labelWeight) {
                    Text("常规").tag("regular")
                    Text("中等").tag("medium")
                    Text("半粗").tag("semibold")
                }
                .disabled(!showAppLabels)
            }

            Section("翻页动画") {
                HStack {
                    Text("收尾时长")
                    Slider(value: $pageAnimationDuration, in: 0.18...1.20, step: 0.02)
                    Text(String(format: "%.2f 秒", pageAnimationDuration))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Section("应用图标") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button("选择图像…") { actions.selectAppIcon() }
                            Button("恢复默认") { actions.resetAppIcon() }
                        }
                        Text("支持 PNG、ICNS、JPEG；修改立即作用于程序坞图标。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func restoreDefaults() {
        showDock = true
        showMenuBar = true
        hotkeyEnabled = true
        hotkeyStyle = "controlOptionL"
        iconSize = 92
        columns = 7
        rows = 5
        swipeReversed = true
        defaultPage = 0
        appearanceMode = "system"
        backgroundStyle = "glass"
        backgroundStrength = 0.68
        showAppLabels = true
        labelFontSize = 13
        labelWeight = "medium"
        pageAnimationDuration = 0.58
        actions.setDock(true)
        actions.setMenuBar(true)
        actions.setHotkeyStyle("controlOptionL")
        actions.setHotkey(true)
        actions.reloadLayout()
    }
}
