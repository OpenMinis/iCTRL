import SwiftUI
import UniformTypeIdentifiers

/// The on-device DDI mounting flow.
///
/// Presented from the Automation section when no image is mounted. Deliberately
/// laid out as ordered prerequisites rather than a single button: the mount has
/// three preconditions the user must satisfy in order, and a button that just
/// says "failed" would leave them guessing which one was missing.
struct DDIMountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mounter = DDIMounter()
    @StateObject private var images = DeveloperDiskImageStore()

    @State private var showPairingPicker = false
    @State private var pairingError: String?
    @State private var hasPairingFile = PairingFileStore.exists
    @State private var imagesReady = DeveloperDiskImageStore.isComplete
    @State private var downloadError: String?
    @State private var vpnInstalled = false
    @State private var tunnelUp = false
    /// Last connection test through the tunnel, and the interfaces seen then.
    @State private var tunnelProbe: LocalDevVPN.TunnelProbe?
    @State private var interfacesSeen = ""
    @State private var probing = false
    @State private var onWiFi = false
    @State private var networkObserved = false

    /// All three prerequisites, in the order the steps present them. The tunnel
    /// is included because it drops on every reboot — leaving it out let the
    /// mount fail with a socket error naming nothing the user could act on.
    /// All prerequisites, in the order the steps present them. Wi-Fi is included
    /// because the tunnel needs a local interface that cellular doesn't offer.
    private var canMount: Bool {
        hasPairingFile && imagesReady && onWiFi && tunnelUp && !mounter.isRunning
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.t(.mountIntro))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // Order matters: download the image before touching the VPN.
                // The tunnel takes over local networking, so fetching ~100MB
                // afterwards is asking for a stalled download.
                // Pairing file first: it is the one step that needs another
                // machine, so surfacing it early avoids finishing the on-device
                // steps only to discover a Mac is required.
                pairingSection
                imageSection
                wifiSection
                tunnelSection
                mountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t(.mountTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t(.doneButton)) { dismiss() }
                }
            }
            .onAppear {
                refreshVPNState()
                subscribeToNetworkOnce()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in refreshVPNState() }
            .onOpenURL { url in
                if !url.isFileURL { refreshVPNState() }   // LocalDevVPN bounced us back
            }
            .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in
                hasPairingFile = true
                pairingError = nil
            }
            // LocalDevVPN bounces back a fixed second after it starts
            // connecting, often before the tunnel is up: keep checking until it is.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if !tunnelUp { refreshVPNState() }
            }
            .sheet(isPresented: $showPairingPicker) {
                PairingFilePicker { url in
                    // The picker's copy holds the pairing secret: drop it once stored.
                    defer { try? FileManager.default.removeItem(at: url) }
                    do {
                        try PairingFileStore.importFile(from: url)
                        hasPairingFile = true
                        pairingError = nil
                    } catch {
                        pairingError = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    /// Names the first unmet prerequisite, so a disabled button explains itself.
    private var missingPrerequisite: String {
        if !hasPairingFile { return L10n.t(.noPairingFile) }
        if !imagesReady { return L10n.t(.imagesNotDownloaded) }
        if !onWiFi { return L10n.t(.notOnWiFi) }
        if !tunnelUp {
            if tunnelProbe == .localNetworkDenied { return L10n.t(.localNetworkDeniedDetail) }
            return vpnInstalled ? L10n.t(.vpnNotConnected) : L10n.t(.vpnNotInstalled)
        }
        return "something is missing"
    }

    /// …and subscribe once for later changes.
    ///
    /// NWPathMonitor resolves asynchronously, so a single read at appear returns
    /// the pre-update default — which reported "not on Wi-Fi" on a device that
    /// plainly was. The observer fires immediately when the path is already
    /// known, and again whenever it changes. Guarded because refreshVPNState
    /// runs on every appear and return-to-foreground; subscribing there would
    /// stack observers that never go away.
    private func subscribeToNetworkOnce() {
        guard !networkObserved else { return }
        networkObserved = true
        NetworkTypeMonitor.shared.observe { type in
            Task { @MainActor in onWiFiChanged(type == .wifi) }
        }
    }

    /// Hop back to the main actor for the @State write.
    @MainActor private func onWiFiChanged(_ connected: Bool) { onWiFi = connected }

    private func refreshVPNState() {
        vpnInstalled = LocalDevVPN.isInstalled
        // Up means a connection through the tunnel worked — not that some
        // address looks right: another VPN can use the same range, and
        // LocalDevVPN's addresses are configurable. One probe at a time; the
        // timer fires faster than a failing probe returns.
        if !probing {
            probing = true
            Task { @MainActor in
                let result = await LocalDevVPN.probeTunnel()
                tunnelProbe = result
                interfacesSeen = LocalDevVPN.interfaceSummary()
                tunnelUp = result == .reachable
                probing = false
            }
        }
        // Read the current value on every refresh…
        onWiFi = NetworkTypeMonitor.shared.current == .wifi
    }

    // ① The tunnel. LocalDevVPN exposes localdevvpn://enable?scheme=…, so this
    //    can send the user straight into connecting and get them back, instead
    //    of just naming an app and hoping.
    private var tunnelSection: some View {
        Section {
            stepRow(4, done: tunnelUp,
                    title: L10n.t(.startLocalDevVPN),
                    detail: tunnelUp
                        ? "\(L10n.t(.tunnelUpDetail)) (\(DDIMounter.tunnelAddress))"
                        : tunnelProbe == .localNetworkDenied
                          ? L10n.t(.localNetworkDeniedDetail)
                          : vpnInstalled
                            ? "\(L10n.t(.vpnInstalledDetail)) (\(DDIMounter.tunnelAddress))"
                            : L10n.t(.vpnMissingDetail))

            if !tunnelUp, tunnelProbe == .localNetworkDenied {
                actionButton(L10n.t(.openSettings)) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            } else if !tunnelUp {
                actionButton(vpnInstalled ? L10n.t(.openVPNAndConnect) : L10n.t(.getVPNFromAppStore)) {
                    // enable? starts the tunnel and bounces back to us; the bare
                    // App Store link is the fallback when it isn't installed.
                    UIApplication.shared.open(vpnInstalled ? LocalDevVPN.enableURL
                                                           : LocalDevVPN.appStoreURL)
                }
            }
        } header: {
            Text(L10n.t(.prerequisiteHeader))
        } footer: {
            if tunnelUp {
                Text(L10n.t(.tunnelDetectedFooter))
            } else if case .unreachable? = tunnelProbe, vpnInstalled {
                // Connected but still not found: show what is there, so a
                // changed tunnel address is visible at a glance.
                Text(L10n.t(.cannotStartVPNFooter) + "\n\n" + L10n.t(.interfacesSeen) + " " + interfacesSeen)
            } else {
                Text(L10n.t(.cannotStartVPNFooter))
            }
        }
    }

    // ② Wi-Fi. The tunnel rides the local network interface, which cellular
    //    does not provide — so any Wi-Fi will do, but some Wi-Fi is required.
    private var wifiSection: some View {
        Section {
            stepRow(3, done: onWiFi,
                    title: L10n.t(.wifiRequired),
                    detail: onWiFi ? L10n.t(.wifiConnected) : L10n.t(.wifiMissing))
        } footer: {
            Text(L10n.t(.wifiFooter))
        }
    }

    // ② The pairing file — proves to lockdownd that we're a trusted host.
    private var pairingSection: some View {
        Section {
            stepRow(1, done: hasPairingFile,
                    title: L10n.t(.importPairingFile),
                    detail: hasPairingFile
                        ? "\(L10n.t(.pairingImported))\(PairingFileStore.importedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")"
                        : L10n.t(.pairingHint))

            actionButton(hasPairingFile ? L10n.t(.replacePairingFile) : L10n.t(.choosePairingFile)) {
                showPairingPicker = true
            }

            if hasPairingFile {
                actionButton(L10n.t(.removePairingFile), role: .destructive) {
                    PairingFileStore.remove()
                    hasPairingFile = false
                }
            }

            if let pairingError {
                Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // ③ The image itself.
    private var imageSection: some View {
        Section {
            stepRow(2, done: imagesReady,
                    title: L10n.t(.ddiComponentTitle),
                    detail: imagesReady
                        ? "\(L10n.t(.ddiDownloaded)) · \(ByteCountFormatter.string(fromByteCount: DeveloperDiskImageStore.totalBytesOnDisk, countStyle: .file))"
                        : L10n.t(.ddiDownloadHint))

            if images.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: images.progress)
                    if let msg = images.statusMessage {
                        Text(msg).font(.caption2).foregroundColor(.secondary)
                    }
                }
            } else if !imagesReady {
                actionButton(L10n.t(.downloadImageFiles)) {
                    Task {
                        do {
                            try await images.download()
                            imagesReady = DeveloperDiskImageStore.isComplete
                            downloadError = nil
                        } catch {
                            downloadError = error.localizedDescription
                        }
                    }
                }
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } footer: {
            Text(L10n.t(.ddiSourceFooter))
        }
    }

    private var mountSection: some View {
        Section {
            switch mounter.phase {
            case .idle, .failed:
                Button {
                    Task { await mounter.mount() }
                } label: {
                    Label(L10n.t(.mountButton), systemImage: "externaldrive.badge.plus")
                }
                .disabled(!canMount)

            case .connecting, .queryingDevice, .finalizing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(phaseLabel).foregroundColor(.secondary)
                }

            case .uploading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text("\(L10n.t(.uploadingImage)) \(Int(fraction * 100))%")
                        .font(.caption).foregroundColor(.secondary)
                }

            case .mounted:
                Label(L10n.t(.mountedOK),
                      systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }

            if case .failed(let message) = mounter.phase {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.t(.mountFailed), systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if case .mounted = mounter.phase {
                Text(L10n.t(.mountNotPersistentFooter))
            } else if !canMount, !mounter.isRunning {
                Text("\(L10n.t(.finishStepsFirst)) — \(missingPrerequisite).")
            } else {
                Text(L10n.t(.firstMountNetworkFooter))
            }
        }
    }

    private var phaseLabel: String {
        switch mounter.phase {
        case .connecting:     return "Connecting through the tunnel…"
        case .queryingDevice: return "Reading device identity…"
        case .finalizing:     return "Finalizing…"
        default:              return ""
        }
    }

    /// One numbered step: badge, title, explanation.
    ///
    /// The badge is the row's `Label` icon, so SwiftUI indents the text to a
    /// consistent leading edge — and `actionButton` pads to match, which is what
    /// keeps a step's button aligned with its own text instead of the card edge.
    private func stepRow(_ n: Int, done: Bool, title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(done ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            stepBadge(n, done: done)
        }
    }

    /// A step's action, indented to line up with that step's text.
    ///
    /// `.body` rather than `.footnote`: these are the things the user is meant
    /// to tap, and at caption size they read as annotations instead of actions.
    private func actionButton(_ title: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        // Built as a Label with an INVISIBLE badge rather than a guessed
        // padding: the real indent is the badge width plus whatever spacing
        // Label uses, which varies with Dynamic Type. Reusing the same layout
        // makes the text land exactly under the step title by construction.
        Button(role: role, action: action) {
            Label {
                Text(title)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                stepBadge(0, done: false).hidden()
            }
        }
    }

    private func stepBadge(_ n: Int, done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.accentColor)
                .frame(width: 22, height: 22)
            if done {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            } else {
                Text(verbatim: "\(n)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
            }
        }
    }
}

/// Document picker that hands back a copy of the chosen file.
///
/// `.fileImporter` opens files in place, and on some devices a file picked
/// from On My iPhone then never reaches the completion handler: the picker
/// stays up with no import and no error. Asking for a copy avoids that, and a
/// copy is all the import needs.
private struct PairingFilePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: PairingFileStore.supportedContentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
