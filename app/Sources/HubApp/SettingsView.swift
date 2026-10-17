import AppKit
import HubCore
import SwiftUI

/// Settings: the terminal theme (a preset, then any colour changed by hand) and the font.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Preset", selection: presetBinding) {
                    ForEach(TerminalTheme.presets) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                    if !isPreset {
                        Text("Custom").tag("Custom")
                    }
                }
                ColorPicker("Background", selection: colour(\.background), supportsOpacity: false)
                ColorPicker("Text", selection: colour(\.foreground), supportsOpacity: false)
                ColorPicker("Cursor", selection: colour(\.cursor), supportsOpacity: false)
                ColorPicker("Selection", selection: colour(\.selection), supportsOpacity: false)
                LabeledContent("Palette") { Swatches(theme: model.appearance.theme) }
            }
            Section("Font") {
                TextField("Family", text: $model.appearance.fontName)
                Stepper(value: $model.appearance.fontSize, in: 9...28, step: 0.5) {
                    LabeledContent("Size", value: "\(model.appearance.fontSize.formatted()) pt")
                }
                if NSFont(name: model.appearance.fontName, size: 12) == nil {
                    Text("Not installed; the system monospaced font is used.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button("Match Orca (Ayu Dark, JetBrainsMono Nerd Font 14)") { model.appearance = .orca }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isPreset: Bool { TerminalTheme.presets.contains(model.appearance.theme) }

    private var presetBinding: Binding<String> {
        Binding {
            isPreset ? model.appearance.theme.name : "Custom"
        } set: { name in
            if let preset = TerminalTheme.presets.first(where: { $0.name == name }) {
                model.appearance.theme = preset
            }
        }
    }

    /// A theme colour as a SwiftUI colour; picking one makes the theme custom.
    private func colour(_ key: WritableKeyPath<TerminalTheme, String>) -> Binding<Color> {
        Binding {
            TerminalTheme.color(model.appearance.theme[keyPath: key])
        } set: { picked in
            guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
            var theme = model.appearance.theme
            theme[keyPath: key] = TerminalTheme.hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            if TerminalTheme.presets.contains(where: { $0.name == theme.name && $0 != theme }) {
                theme.name = "Custom"
            }
            model.appearance.theme = theme
        }
    }
}

/// The 16 ANSI colours, normal over bright.
struct Swatches: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(spacing: 3) {
            ForEach([0, 8], id: \.self) { start in
                HStack(spacing: 3) {
                    ForEach(start..<start + 8, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(TerminalTheme.color(theme.ansi[index]))
                            .frame(width: 16, height: 16)
                    }
                }
            }
        }
        .padding(4)
        .background(TerminalTheme.color(theme.background), in: RoundedRectangle(cornerRadius: 5))
    }
}
