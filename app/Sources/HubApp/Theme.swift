import AppKit
import HubCore
import SwiftUI

/// The Ledger look: cool paper, ink blue, and a highlighter that only ever means "this needs you".
/// Every colour has a dark-mode twin.
enum Ledger {
    static let desk = dynamic(0xE9EDF2, 0x14171C) { $0.background }
    static let paper = dynamic(0xFBFCFD, 0x1B1F26) { $0.surface }
    static let ink = dynamic(0x14213D, 0xE6E9EF) { $0.text }
    static let ink2 = dynamic(0x56627A, 0xA6AFBD) { CustomLook.mix($0.text, $0.surface, 0.3) }
    /// The quietest text; still 4.5:1 or better on every fill it sits on.
    static let ink3 = dynamic(0x616B80, 0x949DAE) { CustomLook.mix($0.text, $0.surface, 0.4) }
    static let rule = dynamic(0xD5DBE4, 0x2E343F) { CustomLook.mix($0.surface, $0.text, 0.14) }
    static let wash = dynamic(0xF1F4F8, 0x232832) { CustomLook.mix($0.surface, $0.text, 0.05) }
    static let selected = dynamic(0xEEF2FA, 0x253049) { CustomLook.mix($0.surface, $0.accent, 0.12) }
    // Areas are told apart by fills, not lines.
    /// The strip the repo tabs sit on.
    static let strip = dynamic(0xEEF1F5, 0x20252D) { CustomLook.mix($0.background, $0.surface, 0.4) }
    /// The picked repo tab.
    static let pill = dynamic(0xFFFFFF, 0x2C323D) { CustomLook.mix($0.surface, $0.dark ? $0.text : "#ffffff", 0.1) }
    /// An agent's header band in the ledger, and a panel's title row.
    static let band = dynamic(0xF4F6F9, 0x1F242C) { CustomLook.mix($0.background, $0.surface, 0.6) }
    /// A Needs you item's card.
    static let needCard = dynamic(0xFFFBE6, 0x2E2A16) { CustomLook.mix($0.surface, $0.highlighter, $0.dark ? 0.12 : 0.16) }
    /// Secondary buttons.
    static let fill = dynamic(0xE9EDF2, 0x2A303A) { CustomLook.mix($0.surface, $0.text, 0.09) }
    /// Text fields and pickers.
    static let field = dynamic(0xEEF1F5, 0x232832) { CustomLook.mix($0.surface, $0.text, 0.06) }
    /// The picked one of a few choices, like a mode card.
    static let chosen = dynamic(0xDFE6F3, 0x2C3956) { CustomLook.mix($0.surface, $0.accent, 0.22) }
    /// The highlighter. Text on it is always dark ink, in both modes.
    static let marker = dynamic(0xFFE347, 0xFFE347) { $0.highlighter }
    static let markerInk = rgb(0x14213D)
    static let markerWash = dynamic(0xFFFBE0, 0x302B14) { CustomLook.mix($0.surface, $0.highlighter, $0.dark ? 0.12 : 0.14) }
    static let run = dynamic(0x2F5BE0, 0x7C9BFF) { $0.accent }
    static let done = dynamic(0x23804B, 0x5BC48C)
    static let fail = dynamic(0xC63A2E, 0xF07A6F)
    /// A file changed but not committed, in the Files column; amber, apart from added green.
    static let changed = dynamic(0x9A6700, 0xE3B341)
    /// Lines an agent just changed in an open preview, for a moment.
    static let justChanged = dynamic(0xFFF4C2, 0x3A3418) { CustomLook.mix($0.surface, $0.highlighter, $0.dark ? 0.18 : 0.3) }
    static let okWash = dynamic(0xEAF5EE, 0x1C2E24)
    static let okInk = dynamic(0x1D5C38, 0x95DAB3)
    static let failWash = dynamic(0xFBECEB, 0x3A1F1D)
    static let failInk = dynamic(0x7D221D, 0xF4B6B0)

    static let mono = Font.system(size: 12, design: .monospaced)

    private static func rgb(_ hex: Int) -> Color {
        Color(nsColor: nsColor(hex))
    }

    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The human's colours while Window's Appearance is Custom; nil for Echo's own.
    nonisolated(unsafe) private(set) static var custom: CustomLook?

    /// Sets the whole app's appearance (nil follows macOS) and Custom's colours.
    @MainActor static func apply(custom: CustomLook?, appearance name: NSAppearance.Name?) {
        let recolour = custom != self.custom
        self.custom = custom
        guard let app = NSApp else { return }
        if recolour {
            // The colours resolve again only when the appearance changes: pass through the same
            // mode's high-contrast twin for a moment, so every view redraws with the new ones.
            let dark = name.map { $0 == .darkAqua }
                ?? (app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            app.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        }
        app.appearance = name.flatMap { NSAppearance(named: $0) }
    }

    /// A token with its light and dark value, and how Custom makes it from the picked colours; a
    /// token without one takes its value for Custom's base mode.
    private static func dynamic(_ light: Int, _ dark: Int, custom: ((CustomLook) -> String)? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if let look = Ledger.custom {
                if let custom, let c = TerminalTheme.rgb(custom(look)) {
                    return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
                }
                return nsColor(look.dark ? dark : light)
            }
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        })
    }
}

extension WorkerRow {
    /// Running blue, done green, anything that settled badly red.
    var markColor: Color {
        if isActive { return Ledger.run }
        return isTrouble ? Ledger.fail : Ledger.done
    }

    /// "Running", "Done", "Blocked", "Exited", "Lost".
    var phaseLabel: String {
        isActive ? "Running" : phase.prefix(1).uppercased() + phase.dropFirst()
    }
}

extension SessionInfo {
    /// The repo path with the home folder as `~`.
    var shortPath: String {
        let home = NSHomeDirectory()
        return repo.hasPrefix(home) ? "~" + repo.dropFirst(home.count) : repo
    }
}

/// A Worker's state as a small square.
struct StateMark: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// Text under the highlighter: reserved for things waiting on the human.
struct Marked: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .fontWeight(.medium)
            .foregroundStyle(Ledger.markerInk)
            .padding(.horizontal, 3)
            .background(Ledger.marker, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// The ledger's buttons: solid ink for the action that moves work forward, a quiet fill for the rest.
struct LedgerButtonStyle: ButtonStyle {
    var primary = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, primary: primary, large: large)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, large ? 14 : 10)
                .padding(.vertical, large ? 8 : 5)
                .foregroundStyle(primary ? Ledger.paper : Ledger.ink)
                .background(primary ? Ledger.ink : Ledger.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == LedgerButtonStyle {
    static var ledger: LedgerButtonStyle { LedgerButtonStyle() }
    static var ledgerPrimary: LedgerButtonStyle { LedgerButtonStyle(primary: true) }
    static var ledgerLarge: LedgerButtonStyle { LedgerButtonStyle(primary: true, large: true) }
}

/// A blue text link, for quiet actions like Show all.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Ledger.run)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var ledgerLink: LinkButtonStyle { LinkButtonStyle() }
}

extension View {
    /// A sheet of paper on the desk, set apart by its fill alone.
    func ledgerSheet() -> some View {
        background(Ledger.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// A text field filled rather than outlined; pair with `.textFieldStyle(.plain)`.
    func ledgerField() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Ledger.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A section title in the ledger: name, count, and an optional action on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let count {
                Text("\(count)").font(.system(size: 12.5)).foregroundStyle(Ledger.ink3).monospacedDigit()
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int?) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Echo's mark for the top bar: one solid square and the echoes it sends out, light on an ink
/// tile, with the highlighter's dot; the app icon is too fine to read at this size.
struct EchoMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 32
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 32 * s, height: 32 * s), cornerRadius: 8 * s, style: .continuous),
                         with: .color(Ledger.markerInk))
            // The mark sits on a 16-unit grid, centred in the tile.
            let unit = 22 * s / 16
            let origin = CGPoint(x: 5 * s, y: 5 * s)
            func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat, _ radius: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: side * unit, height: side * unit),
                     cornerRadius: radius * unit, style: .continuous)
            }
            let paper = Color(white: 0.985)
            context.stroke(square(7, 1.5, 7.5, 1.8), with: .color(paper.opacity(0.45)), lineWidth: 1.1 * unit)
            context.stroke(square(4.5, 4, 7.5, 1.8), with: .color(paper.opacity(0.7)), lineWidth: 1.1 * unit)
            context.fill(square(1.5, 7, 7.5, 1.8), with: .color(paper))
            context.fill(square(5.6, 11.1, 2, 0.5), with: .color(Ledger.marker))
        }
        .accessibilityHidden(true)
    }
}
