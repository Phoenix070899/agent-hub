import Foundation

/// A terminal colour scheme: the 16 ANSI colours plus background, text, cursor, and selection.
/// Colours are `#rrggbb`.
public struct TerminalTheme: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var background: String
    public var foreground: String
    public var cursor: String
    public var selection: String
    /// black, red, green, yellow, blue, magenta, cyan, white, then the bright eight.
    public var ansi: [String]

    public var id: String { name }

    public init(name: String, background: String, foreground: String, cursor: String, selection: String, ansi: [String]) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }

    /// Whether its background is dark, so the window around it should be too.
    public var isDark: Bool {
        guard let c = Self.rgb(background) else { return true }
        return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue < 0.5
    }

    /// Orca's "Ayu Dark", the theme the human's Orca terminal uses.
    public static let ayuDark = TerminalTheme(
        name: "Ayu Dark", background: "#0a0e14", foreground: "#b3b1ad", cursor: "#e6b450", selection: "#273747",
        ansi: ["#01060e", "#ea6c73", "#91b362", "#f9af4f", "#53bdfa", "#fae994", "#90e1c6", "#c7c7c7",
               "#686868", "#f07178", "#c2d94c", "#ffb454", "#59c2ff", "#ffee99", "#95e6cb", "#ffffff"]
    )

    /// Orca's "Builtin Tango Light", its light-mode terminal theme.
    public static let tangoLight = TerminalTheme(
        name: "Tango Light", background: "#ffffff", foreground: "#2e3434", cursor: "#2e3434", selection: "#accef7",
        ansi: ["#2e3436", "#cc0000", "#4e9a06", "#8e7700", "#3465a4", "#75507b", "#05727e", "#6a6a6a",
               "#555753", "#ef2929", "#1b7a1b", "#6d5a00", "#204a87", "#ad7fa8", "#034b50", "#3d3d3d"]
    )

    /// The Hub's first look: a neutral dark with the xterm palette.
    public static let hubDark = TerminalTheme(
        name: "Hub Dark", background: "#171a1f", foreground: "#e0e0e0", cursor: "#0a84ff", selection: "#264f78",
        ansi: ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
               "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#e5e5e5"]
    )

    public static let presets = [ayuDark, tangoLight, hubDark]

    /// Red, green, and blue in 0...1, or nil for anything but `#rrggbb`.
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// `#rrggbb` for colour components in 0...1.
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        let byte = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}

/// The terminal look the human chose: a preset, their colour overrides, and the font.
public struct TerminalAppearance: Codable, Equatable, Sendable {
    public var theme: TerminalTheme
    public var fontName: String
    public var fontSize: Double

    /// Matches the human's Orca terminal: Ayu Dark in JetBrainsMono Nerd Font 14.
    public static let orca = TerminalAppearance(theme: .ayuDark, fontName: "JetBrainsMono Nerd Font", fontSize: 14)

    public init(theme: TerminalTheme, fontName: String, fontSize: Double) {
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
    }
}
