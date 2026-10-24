import AppKit
import CoreImage.CIFilterBuiltins
import HubCore
import SwiftUI

/// Settings' Remote section: Echo Remote on or off, and the QR code a phone scans to pair (ADR 0008).
struct RemoteSettings: View {
    @StateObject private var remote = RemoteModel()

    var body: some View {
        Section {
            Toggle("Echo Remote", isOn: Binding(get: { remote.status?.enabled ?? false }, set: remote.turn))
                .disabled(remote.status == nil || remote.busy)
            if let line = remote.line {
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if remote.status?.tailscale == "missing" {
                Link("Get Tailscale for this Mac and your phone", destination: URL(string: "https://tailscale.com/download")!)
                    .font(.caption)
            }
            if let status = remote.status, status.enabled, status.url != nil || status.tailscale == "test", let link = status.pairLink {
                HStack(alignment: .top, spacing: 16) {
                    QRCode(text: link)
                        .frame(width: 148, height: 148)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with your phone's camera to pair it.")
                        Text("Then tap Share, Add to Home Screen, open Echo from there, and turn on notifications in its Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                            }
                            Button("New Pairing Link…", action: remote.confirmNewPairing)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Your agents' ledger, Needs, and screens on your phone, through Tailscale only. Whoever has the pairing link can drive your agents; keep it private.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            // Tailscale may be installed or logged in while Settings is open.
            while !Task.isCancelled {
                remote.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

@MainActor
final class RemoteModel: ObservableObject {
    @Published var status: RemoteStatus?
    @Published var busy = false
    @Published var failure: String?
    private let client = DaemonClient()

    struct Line {
        let text: String
        let problem: Bool
    }

    /// One line on how it stands: a problem first, then where the phone finds it.
    var line: Line? {
        if let failure { return Line(text: failure, problem: true) }
        guard let status else { return nil }
        if let error = status.error { return Line(text: error, problem: true) }
        guard status.enabled else { return Line(text: "Off. Turn it on to pair a phone.", problem: false) }
        if let url = status.url { return Line(text: "On at \(url) on your tailnet. Phones with notifications: \(status.phones).", problem: false) }
        switch status.tailscale {
        case "missing": return Line(text: "On, but only on this Mac: Tailscale is not installed.", problem: true)
        case "test": return Line(text: "On at \(status.local) (test daemon; Tailscale left alone).", problem: false)
        default: return Line(text: "On, but only on this Mac: \(status.tailscale)", problem: true)
        }
    }

    func refresh() { run("remote.status") }

    func turn(_ on: Bool) { run(on ? "remote.enable" : "remote.disable") }

    func confirmNewPairing() {
        let alert = NSAlert()
        alert.messageText = "Make a new pairing link?"
        alert.informativeText = "Every phone paired now stops working until it scans the new code."
        alert.addButton(withTitle: "New Link")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { run("remote.pair") }
    }

    private func run(_ method: String) {
        if method != "remote.status" { busy = true }
        let client = client
        Task.detached {
            let result = Result { try client.remote(method) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let status):
                    self.status = status
                    self.failure = nil
                case .failure(let error):
                    self.failure = "The Hub Daemon did not answer: \(error)"
                }
            }
        }
    }
}

/// A QR code drawn crisp at any size.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
