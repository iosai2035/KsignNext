import SwiftUI
import Network

/// Local install server (NWListener, plain HTTP on the LAN). Serves an itms-services
/// manifest for a signed IPA in Documents/SignedApps. Start/stop are real listener calls;
/// if the listener fails to start, the error is shown — never reported as running.
@MainActor
final class InstallationViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt16 = 8080
    @Published var installURLString = ""
    @Published var errorMessage: String?
    @Published var signedApps: [String] = []
    @Published var selectedApp = ""

    private var listener: NWListener?
    private var serverQueue = DispatchQueue(label: "com.ksignnext.install-server")

    func refreshSignedApps() {
        guard let docs = Workspace.documents else { return }
        let dir = docs.appendingPathComponent("SignedApps", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        signedApps = items.filter { $0.pathExtension.lowercased() == "ipa" }.map(\.lastPathComponent).sorted()
        if selectedApp.isEmpty { selectedApp = signedApps.first ?? "" }
    }

    func startServer() {
        guard !selectedApp.isEmpty else {
            errorMessage = NSLocalizedString("install.error.noapp", comment: ""); return
        }
        let params = NWParameters.tcp
        do {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { errorMessage = NSLocalizedString("install.error.noapp", comment: ""); return }
            let listener = try NWListener(using: params, on: endpointPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.installURLString = "itms-services://?action=download-manifest&url=http://\(self?.localAddress() ?? "localhost"):\(self?.port ?? 8080)/manifest.plist"
                    case .failed(let error):
                        self?.isRunning = false
                        self?.errorMessage = error.localizedDescription
                    default: break
                    }
                }
            }
            listener.start(queue: serverQueue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        isRunning = false
        installURLString = ""
    }

    private func localAddress() -> String {
        var address = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
        }
        return address
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            let manifest = self.manifestPlist()
            let body = Data(manifest.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            _ = data
        }
    }

    private func manifestPlist() -> String {
        let ipaURL = "http://\(localAddress()):\(port)/\(selectedApp.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedApp)"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>items</key><array><dict>
        <key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>\(ipaURL)</string></dict></array>
        <key>metadata</key><dict><key>bundle-identifier</key><string>com.ksignnext.app</string><key>bundle-version</key><string>1.0</string><key>kind</key><string>software</string><key>title</key><string>\(selectedApp)</string></dict>
        </dict></array></dict></plist>
        """
    }

    var sideStoreSteps: [String] {
        (1...5).map { String(format: NSLocalizedString("install.sidestore.step", comment: ""), $0) }
    }

    func sideStoreExportURL() -> URL? {
        guard !selectedApp.isEmpty, let docs = Workspace.documents else { return nil }
        return docs.appendingPathComponent("SignedApps/\(selectedApp)")
    }
}

struct InstallationView: View {
    @StateObject private var viewModel = InstallationViewModel()

    var body: some View {
        List {
            Section(NSLocalizedString("install.section.server", comment: "")) {
                Picker(NSLocalizedString("install.pick.app", comment: ""), selection: $viewModel.selectedApp) {
                    ForEach(viewModel.signedApps, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("install.appPicker")
                HStack {
                    Text(NSLocalizedString("install.status", comment: ""))
                    Spacer()
                    Text(viewModel.isRunning ? NSLocalizedString("install.running", comment: "") : NSLocalizedString("install.stopped", comment: ""))
                        .foregroundStyle(viewModel.isRunning ? .green : .secondary)
                }
                if viewModel.isRunning {
                    Text(viewModel.installURLString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("install.linkText")
                    Button(NSLocalizedString("install.stop", comment: ""), role: .destructive) { viewModel.stopServer() }
                        .accessibilityIdentifier("install.stop")
                } else {
                    Button(NSLocalizedString("install.start", comment: "")) { viewModel.startServer() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("install.start")
                }
            }
            Section(NSLocalizedString("install.section.sidestore", comment: "")) {
                if let url = viewModel.sideStoreExportURL() {
                    ShareLink(item: url, preview: SharePreview(viewModel.selectedApp)) {
                        Label(NSLocalizedString("install.sidestore.export", comment: ""), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("install.sidestoreExport")
                } else {
                    Text(NSLocalizedString("install.error.noapp", comment: "")).foregroundStyle(.secondary)
                }
                ForEach(viewModel.sideStoreSteps.indices, id: \.self) { index in
                    Text(viewModel.sideStoreSteps[index]).font(.caption)
                }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(NSLocalizedString("tab.installation", comment: ""))
        .onAppear { viewModel.refreshSignedApps() }
        .onDisappear { if viewModel.isRunning { viewModel.stopServer() } }
    }
}
